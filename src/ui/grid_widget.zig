//! Spike B (#3): a plain `gtk.Widget` subclass that redraws a 200x60 monospaced text
//! grid from scratch every frame via a tick callback, measuring whether Pango shaping +
//! GSK/cairo compositing sustain ≥60 fps. See roadmap/designs/3-spike-b-gtk4-pango.md.
//!
//! ponytail: the grid is rebuilt and re-shaped in full every frame on purpose — that's
//! the worst case the spike exists to measure (see design "Riesgos"). A real kelpie
//! renderer would only re-shape dirty rows (spike C, #4).
const std = @import("std");
const gobject = @import("gobject");
const glib = @import("glib");
const gtk = @import("gtk");
const gdk = @import("gdk");
const graphene = @import("graphene");
const pango = @import("pango");
const gsk = @import("gsk");

pub const cols = 200;
pub const rows = 60;
const row_len = cols; // ASCII-only rows: 1 byte == 1 char == 1 cell.

/// Row 2 is a contiguous "->" run and row 3 a contiguous "!=" run — the ligature
/// scenario in the design requires a single un-split PangoItem containing these,
/// not one cell shaped at a time.
const ligature_row_arrow = 2;
const ligature_row_neq = 3;

pub const GridWidget = extern struct {
    parent_instance: Parent,
    pango_ctx: ?*pango.Context,
    normal_desc: ?*pango.FontDescription,
    bold_desc: ?*pango.FontDescription,
    row_text: [rows][row_len + 1]u8,
    ready: bool,
    frame_count: u64,
    last_report_us: i64,

    pub const Parent = gtk.Widget;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "KelpieGridWidget",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn as(self: *Self, comptime T: type) *T {
        return gobject.ext.as(T, self);
    }

    fn buildRows(self: *Self) void {
        var prng = std.Random.DefaultPrng.init(0xC0FFEE);
        const random = prng.random();
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

        for (0..rows) |r| {
            if (r == ligature_row_arrow) {
                var i: usize = 0;
                while (i < row_len) : (i += 2) {
                    self.row_text[r][i] = '-';
                    self.row_text[r][i + 1] = '>';
                }
            } else if (r == ligature_row_neq) {
                var i: usize = 0;
                while (i < row_len) : (i += 2) {
                    self.row_text[r][i] = '!';
                    self.row_text[r][i + 1] = '=';
                }
            } else if (r == 0) {
                @memset(self.row_text[r][0..row_len], 'M');
            } else if (r == 1) {
                @memset(self.row_text[r][0..row_len], 'i');
            } else {
                for (0..row_len) |c| {
                    self.row_text[r][c] = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
                }
            }
            self.row_text[r][row_len] = 0;
        }
    }

    /// Reports (once, to stderr) whether the "->" and "!=" runs fused into fewer
    /// glyphs than input chars — the ligature scenario's actual assertion.
    fn reportLigatures(self: *Self) void {
        inline for (.{
            .{ ligature_row_arrow, "->" },
            .{ ligature_row_neq, "!=" },
        }) |entry| {
            const row, const label = entry;
            const text: [*:0]const u8 = @ptrCast(&self.row_text[row]);
            const attrs = pango.AttrList.new();
            defer pango.AttrList.unref(attrs);
            const attr = pango.AttrFontDesc.new(self.normal_desc.?);
            pango.AttrList.insert(attrs, attr);

            const items = pango.itemize(self.pango_ctx.?, text, 0, row_len, attrs, null);
            defer glib.List.free(items);
            var chars: c_int = 0;
            var glyphs: c_int = 0;
            var node: ?*glib.List = items;
            while (node) |n| : (node = n.f_next) {
                const item: *pango.Item = @ptrCast(@alignCast(n.f_data));
                chars += item.f_num_chars;
                const gs = pango.GlyphString.new();
                defer pango.GlyphString.free(gs);
                pango.shape(text + @as(usize, @intCast(item.f_offset)), item.f_length, &item.f_analysis, gs);
                glyphs += gs.f_num_glyphs;
            }
            std.debug.print(
                "spike-b: ligature run \"{s}\" ({d} chars) shaped to {d} glyphs ({s})\n",
                .{ label, chars, glyphs, if (glyphs < chars) "fused" else "NOT fused" },
            );
        }
    }

    fn ensureReady(self: *Self) void {
        if (self.ready) return;
        self.pango_ctx = gtk.Widget.createPangoContext(self.as(gtk.Widget));
        self.normal_desc = pango.FontDescription.new();
        self.normal_desc.?.setFamily("JetBrainsMono Nerd Font");
        self.normal_desc.?.setAbsoluteSize(14.0 * 1024.0);
        self.bold_desc = pango.FontDescription.new();
        self.bold_desc.?.setFamily("JetBrainsMono Nerd Font");
        self.bold_desc.?.setAbsoluteSize(14.0 * 1024.0);
        self.bold_desc.?.setWeight(.bold);

        self.buildRows();
        self.reportLigatures();
        self.ready = true;

        _ = gtk.Widget.addTickCallback(self.as(gtk.Widget), &tick, null, null);
    }

    fn tick(widget: *gtk.Widget, _: *gdk.FrameClock, _: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(widget));
        self.frame_count += 1;

        const now = glib.getMonotonicTime();
        if (self.last_report_us == 0) self.last_report_us = now;
        const elapsed_us = now - self.last_report_us;
        if (elapsed_us >= std.time.us_per_s) {
            const fps = @as(f64, @floatFromInt(self.frame_count)) /
                (@as(f64, @floatFromInt(elapsed_us)) / @as(f64, @floatFromInt(std.time.us_per_s)));
            std.debug.print("spike-b: {d:.1} fps\n", .{fps});
            self.frame_count = 0;
            self.last_report_us = now;
        }

        // Force snapshot() to actually re-run this frame — addTickCallback alone only
        // re-invokes the callback next frame, it does not invalidate the widget.
        gtk.Widget.queueDraw(widget);
        return 1; // G_SOURCE_CONTINUE
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        self.ensureReady();

        const w = gtk.Widget.getWidth(self.as(gtk.Widget));
        const h = gtk.Widget.getHeight(self.as(gtk.Widget));
        if (w <= 0 or h <= 0) return;
        const cell_w = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(cols));
        const cell_h = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(rows));

        var bounds: graphene.Rect = undefined;
        _ = graphene.Rect.init(&bounds, 0, 0, @floatFromInt(w), @floatFromInt(h));
        gtk.Snapshot.appendColor(snap, &.{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = 1 }, &bounds);

        const text_color: gdk.RGBA = .{ .f_red = 0.85, .f_green = 0.85, .f_blue = 0.85, .f_alpha = 1 };

        for (0..rows) |r| {
            const text: [*:0]const u8 = @ptrCast(&self.row_text[r]);
            const attrs = pango.AttrList.new();
            defer pango.AttrList.unref(attrs);

            const normal_attr = pango.AttrFontDesc.new(self.normal_desc.?);
            normal_attr.f_start_index = 0;
            normal_attr.f_end_index = @intCast(row_len);
            pango.AttrList.insert(attrs, normal_attr);

            // Alternate a bold fraction of the row: every other 10-column band.
            var band_start: u32 = 0;
            while (band_start < cols) : (band_start += 20) {
                const band_end = @min(band_start + 10, cols);
                const bold_attr = pango.AttrFontDesc.new(self.bold_desc.?);
                bold_attr.f_start_index = @intCast(band_start);
                bold_attr.f_end_index = @intCast(band_end);
                pango.AttrList.insert(attrs, bold_attr);
            }

            const items = pango.itemize(self.pango_ctx.?, text, 0, row_len, attrs, null);
            defer glib.List.free(items);

            var col: u32 = 0;
            var node: ?*glib.List = items;
            while (node) |n| : (node = n.f_next) {
                const item: *pango.Item = @ptrCast(@alignCast(n.f_data));
                const gs = pango.GlyphString.new();
                defer pango.GlyphString.free(gs);
                pango.shape(
                    text + @as(usize, @intCast(item.f_offset)),
                    item.f_length,
                    &item.f_analysis,
                    gs,
                );

                // Force every glyph's advance to exactly one cell width so columns
                // line up regardless of the glyph's natural metrics.
                const forced_width: pango.GlyphUnit = @intFromFloat(cell_w * 1024.0);
                if (gs.f_glyphs) |glyphs_ptr| {
                    for (glyphs_ptr[0..@intCast(gs.f_num_glyphs)]) |*g| {
                        g.f_geometry.f_width = forced_width;
                    }
                }

                const x = @as(f64, @floatFromInt(col)) * cell_w;
                const y = (@as(f64, @floatFromInt(r)) + 1) * cell_h - cell_h * 0.25;
                var offset: graphene.Point = undefined;
                _ = graphene.Point.init(&offset, @floatCast(x), @floatCast(y));

                // A real gsk.TextNode (not a Cairo raster node): appendCairo/
                // showGlyphString painted glyphs through Cairo's software rasterizer,
                // which is what the human-run fps gate flagged as the scaffolding bug.
                // gsk_text_node_new takes the same already-shaped, width-forced
                // pango.GlyphString and turns it into a genuine GSK render node.
                if (gsk.TextNode.new(item.f_analysis.f_font.?, gs, &text_color, &offset)) |text_node| {
                    gtk.Snapshot.appendNode(snap, text_node.as(gsk.RenderNode));
                    gsk.RenderNode.unref(text_node.as(gsk.RenderNode));
                }

                col += @intCast(item.f_num_chars);
            }
        }
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.pango_ctx = null;
        self.normal_desc = null;
        self.bold_desc = null;
        self.ready = false;
        self.frame_count = 0;
        self.last_report_us = 0;
        gtk.Widget.setSizeRequest(self.as(gtk.Widget), 1200, 900);
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &Self.snapshot);
        }
    };
};
