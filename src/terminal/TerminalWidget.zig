//! TerminalWidget (#21): subclase GObject real de gtk.GLArea que dibuja filas
//! sucias del RenderState con Pango + cairo → texturas GL. El hilo que alimenta
//! nunca pinta (g_idle_add → queueRender). Ver roadmap/designs/21-terminalview.md.
const std = @import("std");
const gobject = @import("gobject");
const glib = @import("glib");
const gio = @import("gio");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const pango = @import("pango");
const pangocairo = @import("pangocairo");
const cairo = @import("cairo");
const graphene = @import("graphene");
const ghostty_vt = @import("ghostty-vt");

const Terminal = ghostty_vt.Terminal;
const RenderState = ghostty_vt.RenderState;

// Raw GL — linked via build.zig linkSystemLibrary("GL"), not a new dependency.
extern "c" fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
extern "c" fn glClear(mask: c_uint) void;
extern "c" fn glViewport(x: c_int, y: c_int, width: c_int, height: c_int) void;
extern "c" fn glEnable(cap: c_uint) void;
extern "c" fn glDisable(cap: c_uint) void;
extern "c" fn glGenTextures(n: c_int, textures: [*c]c_uint) void;
extern "c" fn glDeleteTextures(n: c_int, textures: [*c]const c_uint) void;
extern "c" fn glBindTexture(target: c_uint, texture: c_uint) void;
extern "c" fn glTexImage2D(target: c_uint, level: c_int, internal_format: c_int, width: c_int, height: c_int, border: c_int, format: c_uint, type_: c_uint, pixels: ?*const anyopaque) void;
extern "c" fn glTexParameteri(target: c_uint, pname: c_int, param: c_int) void;
extern "c" fn glTexCoord2f(s: f32, t: f32) void;
extern "c" fn glVertex2f(x: f32, y: f32) void;
extern "c" fn glBegin(mode: c_uint) void;
extern "c" fn glEnd() void;
extern "c" fn glBlendFunc(sfactor: c_uint, dfactor: c_uint) void;
extern "c" fn glPixelStorei(pname: c_int, param: c_int) void;

extern "c" fn usleep(useconds: c_uint) c_int;

const gl_color_buffer_bit: c_uint = 0x00004000;
const gl_texture_2d: c_uint = 0x0DE1;
const gl_rgba: c_uint = 0x1908;
const gl_unsigned_byte: c_uint = 0x1401;
const gl_nearest: c_int = 0x2600;
const gl_texture_min_filter: c_int = 0x2801;
const gl_texture_mag_filter: c_int = 0x2800;
const gl_quads: c_uint = 0x0007;
const gl_blend: c_uint = 0x0BE2;
const gl_src_alpha: c_uint = 0x0302;
const gl_one_minus_src_alpha: c_uint = 0x0303;
const gl_unpack_row_length: c_int = 0x0CF2;
const gl_unpack_alignment: c_int = 0x0CF5;

pub const TerminalWidget = extern struct {
    parent_instance: Parent,
    // Pango/cairo
    pango_ctx: ?*pango.Context,
    normal_desc: ?*pango.FontDescription,
    bold_desc: ?*pango.FontDescription,
    italic_desc: ?*pango.FontDescription,
    bold_italic_desc: ?*pango.FontDescription,
    // Terminal + render state
    terminal: ?*Terminal,
    render_state: ?*RenderState,
    lock_state: std.atomic.Value(u8),
    // alloc and io stored at module level (not extern types)
    // Grid
    grid_cols: u16,
    grid_rows: u16,
    cell_w: f64,
    cell_h: f64,
    // Harness
    frame_count: u64,
    last_report_us: i64,
    ready: bool,

    pub const Parent = gtk.GLArea;
    const Self = @This();

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "KelpieTerminalWidget",
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

    fn getAlloc(_: *Self) std.mem.Allocator {
        return widget_alloc;
    }

    fn spinLock(self: *Self) void {
        while (self.lock_state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn spinUnlock(self: *Self) void {
        self.lock_state.store(0, .release);
    }

    /// Configura el terminal y el render state. Llamar después de new().
    pub fn setup(
        self: *Self,
        io: std.Io,
        alloc: std.mem.Allocator,
        num_cols: u16,
        num_rows: u16,
    ) !void {
        const term_ptr = try alloc.create(Terminal);
        errdefer alloc.destroy(term_ptr);
        term_ptr.* = try Terminal.init(io, alloc, .{ .cols = num_cols, .rows = num_rows });

        const state_ptr = try alloc.create(RenderState);
        state_ptr.* = .empty;

        self.terminal = term_ptr;
        self.render_state = state_ptr;
        self.lock_state = .init(0);
        widget_alloc = alloc;
        widget_io = io;
        self.grid_cols = num_cols;
        self.grid_rows = num_rows;
    }

    pub fn deinitResources(self: *Self) void {
        const alloc = self.getAlloc();
        if (self.render_state) |rs| {
            rs.deinit(alloc);
            alloc.destroy(rs);
            self.render_state = null;
        }
        if (self.terminal) |t| {
            t.deinit(alloc);
            alloc.destroy(t);
            self.terminal = null;
        }
    }

    /// Alimenta bytes al terminal (puede llamarse desde cualquier hilo).
    /// Lock → vtStream → nextSlice → unlock → g_idle_add → queueRender.
    pub fn feed(self: *Self, bytes: []const u8) !void {
        self.spinLock();
        if (self.terminal) |t| {
            var stream = t.vtStream();
            defer stream.deinit();
            stream.nextSlice(bytes);
        }
        self.spinUnlock();

        self.queueRenderFromAnyThread();
    }

    /// Marshal: agenda queueRender en el hilo UI via g_idle_add.
    pub fn queueRenderFromAnyThread(self: *Self) void {
        _ = glib.idleAdd(onIdleQueueRender, self);
    }

    fn onIdleQueueRender(user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(user_data));
        self.as(gtk.GLArea).queueRender();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    // ── GObject callbacks ──────────────────────────────────────────────

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.pango_ctx = null;
        self.normal_desc = null;
        self.bold_desc = null;
        self.italic_desc = null;
        self.bold_italic_desc = null;
        self.terminal = null;
        self.render_state = null;
        self.lock_state = .init(0);
        self.grid_cols = 0;
        self.grid_rows = 0;
        self.cell_w = 0;
        self.cell_h = 0;
        self.frame_count = 0;
        self.last_report_us = 0;
        self.ready = false;
    }

    fn ensureReady(self: *Self) void {
        if (self.ready) return;
        const widget = self.as(gtk.Widget);
        self.pango_ctx = gtk.Widget.createPangoContext(widget);
        self.normal_desc = pango.FontDescription.new();
        self.normal_desc.?.setFamily("Monospace");
        self.normal_desc.?.setAbsoluteSize(14.0 * 1024.0);
        self.bold_desc = pango.FontDescription.new();
        self.bold_desc.?.setFamily("Monospace");
        self.bold_desc.?.setAbsoluteSize(14.0 * 1024.0);
        self.bold_desc.?.setWeight(.bold);
        self.italic_desc = pango.FontDescription.new();
        self.italic_desc.?.setFamily("Monospace");
        self.italic_desc.?.setAbsoluteSize(14.0 * 1024.0);
        self.italic_desc.?.setStyle(.italic);
        self.bold_italic_desc = pango.FontDescription.new();
        self.bold_italic_desc.?.setFamily("Monospace");
        self.bold_italic_desc.?.setAbsoluteSize(14.0 * 1024.0);
        self.bold_italic_desc.?.setWeight(.bold);
        self.bold_italic_desc.?.setStyle(.italic);
        self.ready = true;
    }

    fn onRealize(gl_area: *gtk.GLArea, self: *Self) callconv(.c) void {
        // Make the GL context current so we can set up state.
        const native = gl_area.as(gtk.Widget).getNative() orelse return;
        const surface = native.as(gtk.Native).getSurface() orelse return;
        const gdk_ctx = surface.createGlContext() orelse return;
        gdk_ctx.makeCurrent();

        self.ensureReady();
        self.updateCellMetrics();
    }

    fn onResize(_: *gtk.GLArea, width: c_int, height: c_int, self: *Self) callconv(.c) void {
        if (width <= 0 or height <= 0) return;

        // If we have prior cell metrics, derive new grid dims and resize terminal.
        if (self.cell_w > 0 and self.cell_h > 0 and self.grid_cols > 0 and self.grid_rows > 0) {
            const new_cols: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(width)) / self.cell_w)))));
            const new_rows: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(height)) / self.cell_h)))));
            if (new_cols != self.grid_cols or new_rows != self.grid_rows) {
                self.resizeGridLocked(new_cols, new_rows);
                // Recalculate cell metrics from new grid.
                self.cell_w = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(self.grid_cols));
                self.cell_h = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(self.grid_rows));
            }
        } else if (self.grid_cols > 0 and self.grid_rows > 0) {
            // First resize: just store cell metrics.
            self.cell_w = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(self.grid_cols));
            self.cell_h = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(self.grid_rows));
        }
    }

    fn resizeGridLocked(self: *Self, new_cols: u16, new_rows: u16) void {
        const t = self.terminal orelse return;
        self.spinLock();
        defer self.spinUnlock();
        t.resize(self.getAlloc(), .{ .cols = new_cols, .rows = new_rows }) catch |err| {
            std.log.warn("TerminalWidget: resize failed: {}", .{err});
            return;
        };
        self.grid_cols = new_cols;
        self.grid_rows = new_rows;
    }

    fn updateCellMetrics(self: *Self) void {
        const widget = self.as(gtk.Widget);
        const w = gtk.Widget.getWidth(widget);
        const h = gtk.Widget.getHeight(widget);
        if (self.grid_cols > 0 and self.grid_rows > 0 and w > 0 and h > 0) {
            self.cell_w = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(self.grid_cols));
            self.cell_h = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(self.grid_rows));
        }
    }

    fn onRender(self: *Self, ctx: *gdk.GLContext) callconv(.c) c_int {
        gdk.GLContext.makeCurrent(ctx);

        const term = self.terminal orelse return 1;
        const rs = self.render_state orelse return 1;

        // 1. Lock → beginUpdate → unlock.
        self.spinLock();
        rs.beginUpdate(self.getAlloc(), term) catch |err| {
            self.spinUnlock();
            std.log.warn("TerminalWidget: beginUpdate failed: {}", .{err});
            return 0;
        };
        self.spinUnlock();

        // 2. Viewport.
        const widget = self.as(gtk.Widget);
        const width = gtk.Widget.getWidth(widget);
        const height = gtk.Widget.getHeight(widget);
        if (width > 0 and height > 0) {
            glViewport(0, 0, @intCast(width), @intCast(height));
        }

        // 3. Clear with terminal background.
        const bg = rs.colors.background;
        glClearColor(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );
        glClear(gl_color_buffer_bit);

        // 4. Draw dirty rows via cairo → GL texture.
        self.drawDirtyRows(rs, width, height);

        // 5. endUpdate → clean.
        rs.endUpdate();
        rs.clean();

        // 6. FPS counter.
        self.frame_count += 1;
        const now = glib.getMonotonicTime();
        if (self.last_report_us == 0) self.last_report_us = now;
        const elapsed = now - self.last_report_us;
        if (elapsed >= std.time.us_per_s) {
            const fps = @as(f64, @floatFromInt(self.frame_count)) /
                (@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(std.time.us_per_s)));
            std.debug.print("terminalview: {d:.1} fps ({d} rows, {d}x{d})\n", .{
                fps,
                rs.rows,
                self.grid_cols,
                self.grid_rows,
            });
            self.frame_count = 0;
            self.last_report_us = now;
        }

        return 1;
    }

    fn drawDirtyRows(self: *Self, rs: *RenderState, vp_width: c_int, vp_height: c_int) void {
        if (self.cell_w <= 0 or self.cell_h <= 0) return;
        const cell_h_i: c_int = @intFromFloat(@ceil(self.cell_h));
        const cols = self.grid_cols;

        const row_data = rs.row_data.slice();
        const dirty_flags = row_data.items(.dirty);
        const cells_all = row_data.items(.cells);

        for (dirty_flags, 0..) |is_dirty, y| {
            if (!is_dirty) continue;

            const cells = cells_all[y];
            const num_cells: usize = @intCast(cols);

            // Create cairo surface for this row.
            const surf = cairo.Surface.imageCreate(.argb32, vp_width, cell_h_i);
            defer surf.destroy();
            const cr = cairo.Context.create(surf);
            defer cr.destroy();

            // Background fill.
            const row_bg = rs.colors.background;
            const rs_bg: gdk.RGBA = .{
                .f_red = @as(f32, @floatFromInt(row_bg.r)) / 255.0,
                .f_green = @as(f32, @floatFromInt(row_bg.g)) / 255.0,
                .f_blue = @as(f32, @floatFromInt(row_bg.b)) / 255.0,
                .f_alpha = 1,
            };
            cr.setSourceRgba(
                @floatCast(rs_bg.f_red),
                @floatCast(rs_bg.f_green),
                @floatCast(rs_bg.f_blue),
                @floatCast(rs_bg.f_alpha),
            );
            cr.paint();

            // Draw each cell with Pango.
            var col: usize = 0;
            while (col < num_cells) {
                const cell = cells.get(col);
                const cp = cell.raw.codepoint();
                if (cp == 0) {
                    col += 1;
                    continue;
                }

                // Determine style.
                const has_style = cell.raw.hasStyling();
                const is_bold = has_style and cell.style.flags.bold;
                const is_italic = has_style and cell.style.flags.italic;

                // Select font description.
                const desc = if (is_bold and is_italic)
                    self.bold_italic_desc.?
                else if (is_bold)
                    self.bold_desc.?
                else if (is_italic)
                    self.italic_desc.?
                else
                    self.normal_desc.?;

                // Foreground color.
                const raw_fg: gdk.RGBA = if (has_style) fg_color: {
                    const sfg = cell.style.fg_color;
                    break :fg_color switch (sfg) {
                        .none => .{ .f_red = 0.85, .f_green = 0.85, .f_blue = 0.85, .f_alpha = 1 },
                        .palette => |idx| palette_to_rgba(rs, idx),
                        .rgb => |rgb| .{
                            .f_red = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            .f_green = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            .f_blue = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                            .f_alpha = 1,
                        },
                    };
                } else .{ .f_red = 0.85, .f_green = 0.85, .f_blue = 0.85, .f_alpha = 1 };

                // Background color per cell (if non-default).
                var raw_bg: ?gdk.RGBA = null;
                if (has_style) {
                    const sbg = cell.style.bg_color;
                    raw_bg = switch (sbg) {
                        .none => null,
                        .palette => |idx| palette_to_rgba(rs, idx),
                        .rgb => |rgb| .{
                            .f_red = @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            .f_green = @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            .f_blue = @as(f32, @floatFromInt(rgb.b)) / 255.0,
                            .f_alpha = 1,
                        },
                    };
                }

                // Inverse: swap fg ↔ bg.
                const is_inverse = has_style and cell.style.flags.inverse;
                const fg: gdk.RGBA = if (is_inverse)
                    raw_bg orelse rs_bg
                else
                    raw_fg;
                const cell_bg: ?gdk.RGBA = if (is_inverse)
                    raw_fg
                else
                    raw_bg;

                // Draw cell background.
                if (cell_bg) |bg_rgba| {
                    cr.setSourceRgba(
                        @floatCast(bg_rgba.f_red),
                        @floatCast(bg_rgba.f_green),
                        @floatCast(bg_rgba.f_blue),
                        @floatCast(bg_rgba.f_alpha),
                    );
                    cr.rectangle(
                        @as(f64, @floatFromInt(col)) * self.cell_w,
                        0,
                        self.cell_w,
                        self.cell_h,
                    );
                    cr.fill();
                }

                // Convert codepoint to UTF-8 (null-terminated for Pango).
                var utf8_buf: [5:0]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(@intCast(cp), &utf8_buf) catch {
                    col += 1;
                    continue;
                };
                utf8_buf[utf8_len] = 0;

                // Pango layout for this cell.
                const layout = pangocairo.createLayout(cr);
                defer gobject.Object.unref(gobject.ext.as(gobject.Object, layout));
                const attrs = pango.AttrList.new();
                defer pango.AttrList.unref(attrs);
                const font_attr = pango.AttrFontDesc.new(desc);
                pango.AttrList.insert(attrs, font_attr);
                // Underline.
                if (has_style and cell.style.flags.underline != .none) {
                    pango.AttrList.insert(attrs, pango.attrUnderlineNew(.single));
                }
                // Strikethrough.
                if (has_style and cell.style.flags.strikethrough) {
                    pango.AttrList.insert(attrs, pango.attrStrikethroughNew(1));
                }
                layout.setAttributes(attrs);
                layout.setFontDescription(desc);
                layout.setText(@ptrCast(&utf8_buf), @intCast(utf8_len));

                // Force cell advance.
                const forced_width: pango.GlyphUnit = @intFromFloat(self.cell_w * 1024.0);
                if (layout.getLineReadonly(0)) |line| {
                    if (line.f_runs) |run_node| {
                        const run: *pango.GlyphItem = @ptrCast(@alignCast(run_node.f_data));
                        if (run.f_glyphs) |gs| {
                            if (gs.f_glyphs) |glyphs_ptr| {
                                for (glyphs_ptr[0..@intCast(gs.f_num_glyphs)]) |*g| {
                                    g.f_geometry.f_width = forced_width;
                                }
                            }
                        }
                    }
                }

                // Set foreground and draw.
                cr.setSourceRgba(
                    @floatCast(fg.f_red),
                    @floatCast(fg.f_green),
                    @floatCast(fg.f_blue),
                    @floatCast(fg.f_alpha),
                );
                cr.moveTo(
                    @as(f64, @floatFromInt(col)) * self.cell_w,
                    0,
                );
                pangocairo.showLayout(cr, layout);

                // Advance by grid width (1 for narrow, 2 for wide).
                const gw = cell.raw.gridWidth();
                col += gw;
            }

            // Upload cairo surface to GL texture and draw quad.
            drawRowTexture(surf, @intCast(y), vp_height);
        }
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.GLArea.virtual_methods.render.implement(class, &Self.onRender);
            // resize is a signal, not a virtual — connect in instance init.
        }
    };
};

fn drawRowTexture(surf: *cairo.Surface, row: u16, vp_height: c_int) void {
    const data = surf.imageGetData() orelse return;
    const stride = surf.imageGetStride();
    const surf_w = surf.imageGetWidth();
    const surf_h = surf.imageGetHeight();

    var tex: c_uint = 0;
    glGenTextures(1, &tex);
    glBindTexture(gl_texture_2d, tex);
    glTexParameteri(gl_texture_2d, gl_texture_min_filter, gl_nearest);
    glTexParameteri(gl_texture_2d, gl_texture_mag_filter, gl_nearest);
    glPixelStorei(gl_unpack_row_length, @divTrunc(stride, 4));
    glPixelStorei(gl_unpack_alignment, 1);
    glTexImage2D(
        gl_texture_2d,
        0,
        @intCast(gl_rgba),
        @intCast(surf_w),
        @intCast(surf_h),
        0,
        gl_rgba,
        gl_unsigned_byte,
        data,
    );

    // Draw textured quad in NDC.
    const x0: f32 = -1.0;
    const x1: f32 = 1.0;
    const pix_to_ndc = 2.0 / @as(f32, @floatFromInt(vp_height));
    const y0: f32 = 1.0 - @as(f32, @floatFromInt(row)) * @as(f32, @floatFromInt(surf_h)) * pix_to_ndc;
    const y1_ndc = y0 - @as(f32, @floatFromInt(surf_h)) * pix_to_ndc;

    glEnable(gl_blend);
    glBlendFunc(gl_src_alpha, gl_one_minus_src_alpha);
    glEnable(gl_texture_2d);
    glBindTexture(gl_texture_2d, tex);

    glBegin(gl_quads);
    glTexCoord2f(0, 0);
    glVertex2f(x0, y0);
    glTexCoord2f(1, 0);
    glVertex2f(x1, y0);
    glTexCoord2f(1, 1);
    glVertex2f(x1, y1_ndc);
    glTexCoord2f(0, 1);
    glVertex2f(x0, y1_ndc);
    glEnd();

    glDisable(gl_texture_2d);
    glDisable(gl_blend);
    glDeleteTextures(1, &tex);
}

fn palette_to_rgba(rs: *RenderState, idx: u8) gdk.RGBA {
    const p = rs.colors.palette;
    if (idx < p.len) {
        const c = p[idx];
        return .{
            .f_red = @as(f32, @floatFromInt(c.r)) / 255.0,
            .f_green = @as(f32, @floatFromInt(c.g)) / 255.0,
            .f_blue = @as(f32, @floatFromInt(c.b)) / 255.0,
            .f_alpha = 1,
        };
    }
    return .{ .f_red = 0.85, .f_green = 0.85, .f_blue = 0.85, .f_alpha = 1 };
}

// ── Harness ────────────────────────────────────────────────────────────

const harness_cols: u16 = 200;
const harness_rows: u16 = 60;
const harness_chunk_size: usize = 64 * 1024;
const harness_total_bytes: usize = 1024 * 1024;
const harness_app_id = "dev.kelpie.TerminalViewHarness";

var harness_widget: ?*TerminalWidget = null;
var harness_io: std.Io = undefined;
var harness_alloc: std.mem.Allocator = std.heap.page_allocator;

/// Module-level allocator for TerminalWidget (Allocator is not an extern type).
var widget_alloc: std.mem.Allocator = std.heap.page_allocator;
/// Module-level Io for TerminalWidget (Io is not an extern type).
var widget_io: std.Io = undefined;

pub fn runHarness(io: std.Io, alloc: std.mem.Allocator) u8 {
    harness_alloc = alloc;
    harness_io = io;
    const app = adw.Application.new(harness_app_id, .{});
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, app));

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &harnessActivate, null, .{});

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), 0, null);
    return @intCast(status & 0xFF);
}

fn harnessActivate(app: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    const alloc = harness_alloc;
    const gtk_app = gobject.ext.as(gtk.Application, app);
    const window = adw.ApplicationWindow.new(gtk_app);
    gtk.Window.setDefaultSize(gobject.ext.as(gtk.Window, window), 1600, 900);

    const tv = TerminalWidget.new();
    tv.as(gtk.Widget).setSizeRequest(1600, 900);
    // connect resize signal
    _ = gtk.GLArea.signals.resize.connect(tv, ?*anyopaque, &onHarnessResize, null, .{});
    // connect realize signal
    _ = gtk.Widget.signals.realize.connect(tv, ?*anyopaque, &onHarnessRealize, null, .{});

    adw.ApplicationWindow.setContent(window, tv.as(gtk.Widget));
    gtk.Window.present(gobject.ext.as(gtk.Window, window));

    harness_widget = tv;

    // Setup terminal after realize (via idle).
    _ = glib.idleAdd(onHarnessSetup, alloc.ptr);
}

fn onHarnessRealize(_: *TerminalWidget, _: ?*anyopaque) callconv(.c) void {
    // Terminal setup happens in onHarnessSetup via idle.
}

fn onHarnessSetup(user_data: ?*anyopaque) callconv(.c) c_int {
    const alloc_ptr: *std.mem.Allocator = @ptrCast(@alignCast(user_data));
    const alloc = alloc_ptr.*;
    const tv = harness_widget orelse return @intFromBool(glib.SOURCE_REMOVE);
    tv.setup(harness_io, alloc, harness_cols, harness_rows) catch |err| {
        std.log.warn("harness setup failed: {}", .{err});
        return @intFromBool(glib.SOURCE_REMOVE);
    };

    // Spawn worker thread.
    _ = std.Thread.spawn(.{}, harnessFeedThread, .{ tv, alloc }) catch |err| {
        std.log.warn("harness thread spawn failed: {}", .{err});
        return @intFromBool(glib.SOURCE_REMOVE);
    };

    return @intFromBool(glib.SOURCE_REMOVE);
}

fn onHarnessResize(_: *TerminalWidget, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) void {}

fn harnessFeedThread(tv: *TerminalWidget, alloc: std.mem.Allocator) void {
    _ = alloc;
    // Generate a chunk of printable ASCII.
    var chunk: [harness_chunk_size]u8 = undefined;
    for (&chunk, 0..) |*b, i| {
        b.* = @intCast((i % 94) + 33); // printable ASCII 33–126
    }

    var fed: usize = 0;
    while (fed < harness_total_bytes) {
        tv.feed(&chunk) catch break;
        fed += harness_chunk_size;
        // ~60 Hz: 16.67 ms per chunk.
        _ = usleep(16 * 1000);
    }

    std.debug.print("harness: fed {d} bytes in chunks of {d}\n", .{ fed, harness_chunk_size });
}
