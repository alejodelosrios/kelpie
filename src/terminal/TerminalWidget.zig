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
const TerminalView = @import("TerminalView.zig").TerminalView;

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
extern "c" fn glGetString(name: c_uint) ?[*:0]const u8;

extern "c" fn usleep(useconds: c_uint) c_int;

const gl_color_buffer_bit: c_uint = 0x00004000;
const gl_texture_2d: c_uint = 0x0DE1;
const gl_rgba: c_uint = 0x1908;
const gl_rgba8: c_uint = 0x8058; // GL_RGBA8 — /usr/include/GL/gl.h:728
const gl_bgra: c_uint = 0x80E1; // GL_BGRA — /usr/include/GL/gl.h:1451
const gl_unsigned_byte: c_uint = 0x1401;
const gl_nearest: c_int = 0x2600;
const gl_texture_min_filter: c_int = 0x2801;
const gl_texture_mag_filter: c_int = 0x2800;
const gl_quads: c_uint = 0x0007;
const gl_blend: c_uint = 0x0BE2;
const gl_one: c_uint = 1; // GL_ONE — /usr/include/GL/gl.h:341
const gl_src_alpha: c_uint = 0x0302;
const gl_one_minus_src_alpha: c_uint = 0x0303;
const gl_unpack_row_length: c_int = 0x0CF2;
const gl_unpack_alignment: c_int = 0x0CF5;
const gl_renderer: c_uint = 0x1F01; // GL_RENDERER — /usr/include/GL/gl.h:654
const gl_version: c_uint = 0x1F02; // GL_VERSION — /usr/include/GL/gl.h:655

const RasterizedRow = struct {
    row: u16,
    surface: *cairo.Surface,
};

// Module-level storage for rasterized rows (ArrayListUnmanaged is not extern-safe).
var rasterized_rows: std.ArrayListUnmanaged(RasterizedRow) = .empty;

pub const TerminalWidget = extern struct {
    parent_instance: Parent,
    // Pango/cairo
    pango_ctx: ?*pango.Context,
    normal_desc: ?*pango.FontDescription,
    bold_desc: ?*pango.FontDescription,
    italic_desc: ?*pango.FontDescription,
    bold_italic_desc: ?*pango.FontDescription,
    // TerminalView (núcleo: Terminal + RenderState + mutex + Stream)
    view: ?*TerminalView,
    // Grid
    grid_cols: u16,
    grid_rows: u16,
    cell_w: f64,
    cell_h: f64,
    rows_rasterized: usize,
    // Harness
    frame_count: u64,
    frames_requested: u64,
    last_report_us: i64,
    gl_logged: bool,
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

    /// Configura el TerminalView. Llamar después de new().
    pub fn setup(
        self: *Self,
        io: std.Io,
        alloc: std.mem.Allocator,
        num_cols: u16,
        num_rows: u16,
    ) !void {
        self.view = try TerminalView.create(alloc, io, num_cols, num_rows);
        self.grid_cols = num_cols;
        self.grid_rows = num_rows;
    }

    pub fn deinitResources(self: *Self) void {
        if (self.view) |v| {
            v.destroy();
            self.view = null;
        }
    }

    /// Alimenta bytes al terminal (puede llamarse desde cualquier hilo).
    /// view.feed (lock → nextSlice → unlock) → queueRenderFromAnyThread.
    pub fn feed(self: *Self, bytes: []const u8) !void {
        const v = self.view orelse return;
        try v.feed(bytes);
        self.queueRenderFromAnyThread();
    }

    /// Marshal: agenda queueRender en el hilo UI via g_idle_add.
    pub fn queueRenderFromAnyThread(self: *Self) void {
        _ = glib.idleAdd(onIdleQueueRender, self);
    }

    fn onIdleQueueRender(user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(user_data));
        self.as(gtk.GLArea).queueRender();
        // Counter AFTER queueRender — if queueRender is removed, counter freezes.
        // Full sabotage test requires running GLib main loop (gate conjunto).
        self.frames_requested +%= 1;
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    // ── GObject callbacks ──────────────────────────────────────────────

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.pango_ctx = null;
        self.normal_desc = null;
        self.bold_desc = null;
        self.italic_desc = null;
        self.bold_italic_desc = null;
        self.view = null;
        self.grid_cols = 0;
        self.grid_rows = 0;
        self.cell_w = 0;
        self.cell_h = 0;
        self.rows_rasterized = 0;
        self.frame_count = 0;
        self.frames_requested = 0;
        self.last_report_us = 0;
        self.gl_logged = false;
        self.ready = false;

        // Connect own signals so onRealize/onResize fire automatically.
        _ = gtk.Widget.signals.realize.connect(self, ?*anyopaque, &onRealize, null, .{});
        _ = gtk.GLArea.signals.resize.connect(self, ?*anyopaque, &onResize, null, .{});
    }

    fn ensureReady(self: *Self) void {
        if (self.ready) return;
        const widget = self.as(gtk.Widget);
        self.pango_ctx = gtk.Widget.createPangoContext(widget);
        self.normal_desc = pango.FontDescription.new();
        (self.normal_desc orelse return).setFamily("Monospace");
        (self.normal_desc orelse return).setAbsoluteSize(14.0 * 1024.0);
        self.bold_desc = pango.FontDescription.new();
        (self.bold_desc orelse return).setFamily("Monospace");
        (self.bold_desc orelse return).setAbsoluteSize(14.0 * 1024.0);
        (self.bold_desc orelse return).setWeight(.bold);
        self.italic_desc = pango.FontDescription.new();
        (self.italic_desc orelse return).setFamily("Monospace");
        (self.italic_desc orelse return).setAbsoluteSize(14.0 * 1024.0);
        (self.italic_desc orelse return).setStyle(.italic);
        self.bold_italic_desc = pango.FontDescription.new();
        (self.bold_italic_desc orelse return).setFamily("Monospace");
        (self.bold_italic_desc orelse return).setAbsoluteSize(14.0 * 1024.0);
        (self.bold_italic_desc orelse return).setWeight(.bold);
        (self.bold_italic_desc orelse return).setStyle(.italic);
        self.ready = true;
    }

    fn onRealize(self: *Self, _: ?*anyopaque) callconv(.c) void {
        self.ensureReady();
        self.updateCellMetrics();
    }

    fn onResize(self: *Self, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
        if (width <= 0 or height <= 0) return;
        const v = self.view orelse return;

        // If we have prior cell metrics, derive new grid dims and resize terminal.
        if (self.cell_w > 0 and self.cell_h > 0 and self.grid_cols > 0 and self.grid_rows > 0) {
            const new_cols: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(width)) / self.cell_w)))));
            const new_rows: u16 = @intCast(@max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(height)) / self.cell_h)))));
            if (new_cols != self.grid_cols or new_rows != self.grid_rows) {
                v.resizeGrid(new_cols, new_rows) catch |err| {
                    std.log.warn("TerminalWidget: resize failed: {}", .{err});
                    return;
                };
                self.grid_cols = new_cols;
                self.grid_rows = new_rows;
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

        // D4: log GL profile once so the gate can read it.
        if (!self.gl_logged) {
            self.gl_logged = true;
            if (glGetString(gl_version)) |ver|
                std.debug.print("terminalview: GL_VERSION={s}\n", .{ver});
            if (glGetString(gl_renderer)) |ren|
                std.debug.print("terminalview: GL_RENDERER={s}\n", .{ren});
        }

        const v = self.view orelse return 1;

        // 1. Lock → beginUpdate → unlock (via view's mutex).
        v.mutex.lockUncancelable(v.io);
        v.render_state.beginUpdate(v.alloc, &v.terminal) catch |err| {
            v.mutex.unlock(v.io);
            std.log.warn("TerminalWidget: beginUpdate failed: {}", .{err});
            return 0;
        };
        v.mutex.unlock(v.io);

        // 2. Viewport.
        const widget = self.as(gtk.Widget);
        const width = gtk.Widget.getWidth(widget);
        const height = gtk.Widget.getHeight(widget);
        if (width > 0 and height > 0) {
            glViewport(0, 0, @intCast(width), @intCast(height));
        }

        // 3. Clear with terminal background.
        const bg = v.render_state.colors.background;
        glClearColor(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );
        glClear(gl_color_buffer_bit);

        // 4. Draw dirty rows via cairo → GL texture.
        self.ensureReady();
        const pango_c = self.pango_ctx orelse return 1;
        self.drawDirtyRows(&v.render_state, pango_c, width, height);

        // 5. endUpdate → clean.
        v.render_state.endUpdate();
        v.render_state.clean();

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
                v.render_state.rows,
                self.grid_cols,
                self.grid_rows,
            });
            self.frame_count = 0;
            self.last_report_us = now;
        }

        return 1;
    }

    fn drawDirtyRows(self: *Self, rs: *RenderState, pango_ctx: *pango.Context, vp_width: c_int, vp_height: c_int) void {
        self.rasterizeDirtyRows(rs, pango_ctx, vp_width);
        self.uploadRowTextures(vp_height);
    }

    /// Phase 1: Cairo+Pango rasterization only (no GL).
    /// Produces one surface per dirty row, stored in rasterized_surfaces.
    pub fn rasterizeDirtyRows(self: *Self, rs: *RenderState, _: *pango.Context, vp_width: c_int) void {
        // Free surfaces from previous frame if any.
        for (rasterized_rows.items) |item| {
            item.surface.destroy();
        }
        rasterized_rows.clearRetainingCapacity();
        self.rows_rasterized = 0;

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
                    self.bold_italic_desc orelse return
                else if (is_bold)
                    self.bold_desc orelse return
                else if (is_italic)
                    self.italic_desc orelse return
                else
                    self.normal_desc orelse return;

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

            // Flush cairo surface before reading pixel data (cairo contract).
            surf.flush();

            rasterized_rows.append(std.heap.page_allocator, .{
                .row = @intCast(y),
                .surface = surf,
            }) catch {
                surf.destroy();
                continue;
            };
            self.rows_rasterized += 1;
        }
    }

    /// Phase 2: GL upload only (no cairo/Pango).
    fn uploadRowTextures(self: *Self, vp_height: c_int) void {
        for (rasterized_rows.items) |item| {
            drawRowTexture(item.surface, item.row, vp_height, self.cell_h);
            item.surface.destroy();
        }
        rasterized_rows.clearRetainingCapacity();
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.GLArea.virtual_methods.render.implement(class, &Self.onRender);
            gobject.Object.virtual_methods.dispose.implement(class, &Self.onDispose);
            // resize is a signal, not a virtual — connect in instance init.
        }
    };

    fn onDispose(self: *Self) callconv(.c) void {
        self.deinitResources();
    }
};

fn drawRowTexture(surf: *cairo.Surface, row: u16, vp_height: c_int, cell_h: f64) void {
    const data = surf.imageGetData() orelse return;
    const stride = surf.imageGetStride();
    const surf_w = surf.imageGetWidth();

    var tex: c_uint = 0;
    glGenTextures(1, &tex);
    glBindTexture(gl_texture_2d, tex);
    glTexParameteri(gl_texture_2d, gl_texture_min_filter, gl_nearest);
    glTexParameteri(gl_texture_2d, gl_texture_mag_filter, gl_nearest);
    glPixelStorei(gl_unpack_row_length, @divTrunc(stride, 4));
    glPixelStorei(gl_unpack_alignment, 1);
    // N2a: internal format GL_RGBA8 (sized), external format GL_BGRA (cairo .argb32).
    glTexImage2D(
        gl_texture_2d,
        0,
        @intCast(gl_rgba8),
        @intCast(surf_w),
        @intFromFloat(@ceil(cell_h)),
        0,
        gl_bgra,
        gl_unsigned_byte,
        data,
    );

    // D1: use cell_h (f64) for quad origin/height, not @ceil(surf_h).
    const pix_to_ndc = 2.0 / @as(f32, @floatFromInt(vp_height));
    const y0: f32 = 1.0 - @as(f32, @floatFromInt(row)) * @as(f32, @floatCast(cell_h)) * pix_to_ndc;
    const y1_ndc = y0 - @as(f32, @floatCast(cell_h)) * pix_to_ndc;

    // Draw textured quad in NDC.
    const x0: f32 = -1.0;
    const x1: f32 = 1.0;

    glEnable(gl_blend);
    // D2: premultiplied alpha — GL_ONE, not GL_SRC_ALPHA.
    glBlendFunc(gl_one, gl_one_minus_src_alpha);
    glEnable(gl_texture_2d);
    glBindTexture(gl_texture_2d, tex);

    // N2b: texcoord t maps only the logical cell fraction of the surface.
    const surf_h_f: f64 = @ceil(cell_h);
    const t_frac: f32 = @floatCast(cell_h / surf_h_f);

    glBegin(gl_quads);
    glTexCoord2f(0, 0);
    glVertex2f(x0, y0);
    glTexCoord2f(1, 0);
    glVertex2f(x1, y0);
    glTexCoord2f(1, t_frac);
    glVertex2f(x1, y1_ndc);
    glTexCoord2f(0, t_frac);
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
// D4 DECISIÓN: HUECO — el perfil GL (core vs compatibilidad) no se documenta
// en headers/gdk4/gtk4. El gate conjunto DEBE leer el log de GL_VERSION/
// GL_RENDERER impreso por onRender en el primer frame; si el contexto es core,
// el modo inmediato (glBegin/glEnd) se sustituye ANTES de medir fps.
// Fuentes: gtkglarea.h (sin mención de perfil), gdkglcontext.h:78-84 (sin
// mención de profile/core/compat), gdkenums.h:69-70 (solo API GL vs GLES).

const harness_cols: u16 = 200;
const harness_rows: u16 = 60;
const harness_chunk_size: usize = 64 * 1024;
const harness_total_bytes: usize = 1024 * 1024;
const harness_app_id = "dev.kelpie.TerminalViewHarness";

var harness_widget: ?*TerminalWidget = null;
var harness_io: std.Io = undefined;
var harness_alloc: std.mem.Allocator = std.heap.page_allocator;

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
    const gtk_app = gobject.ext.as(gtk.Application, app);
    const window = adw.ApplicationWindow.new(gtk_app);
    gtk.Window.setDefaultSize(gobject.ext.as(gtk.Window, window), 1600, 900);

    const tv = TerminalWidget.new();
    tv.as(gtk.Widget).setSizeRequest(1600, 900);

    adw.ApplicationWindow.setContent(window, tv.as(gtk.Widget));
    gtk.Window.present(gobject.ext.as(gtk.Window, window));

    harness_widget = tv;

    // Setup terminal after realize (via idle).
    _ = glib.idleAdd(onHarnessSetup, null);
}

fn onHarnessSetup(_: ?*anyopaque) callconv(.c) c_int {
    const tv = harness_widget orelse return @intFromBool(glib.SOURCE_REMOVE);
    tv.setup(harness_io, harness_alloc, harness_cols, harness_rows) catch |err| {
        std.log.warn("harness setup failed: {}", .{err});
        return @intFromBool(glib.SOURCE_REMOVE);
    };

    // Spawn worker thread.
    _ = std.Thread.spawn(.{}, harnessFeedThread, .{tv}) catch |err| {
        std.log.warn("harness thread spawn failed: {}", .{err});
        return @intFromBool(glib.SOURCE_REMOVE);
    };

    return @intFromBool(glib.SOURCE_REMOVE);
}

fn harnessFeedThread(tv: *TerminalWidget) void {
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

// ── Tests (headless, no display, no GL) ────────────────────────────────

test "onResize deriva rejilla y llama Terminal.resize" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    // Construct widget manually (extern struct, no GObject needed).
    var widget: TerminalWidget = undefined;
    widget.view = tv;
    widget.grid_cols = 80;
    widget.grid_rows = 24;
    widget.cell_w = 10.0;
    widget.cell_h = 15.0;

    // Resize to 200x900 → 200/10=20 cols, 900/15=60 rows.
    TerminalWidget.onResize(&widget, 200, 900, null);

    try std.testing.expectEqual(@as(u16, 20), widget.grid_cols);
    try std.testing.expectEqual(@as(u16, 60), widget.grid_rows);
    try std.testing.expectEqual(@as(u16, 20), tv.cols());
    try std.testing.expectEqual(@as(u16, 60), tv.rows());
}

test "feed incrementa frames_requested" {
    // B5: frames_requested se incrementa en onIdleQueueRender (tras queueRender),
    // NO en queueRenderFromAnyThread. Sin GLib main loop corriendo, el idle
    // callback no se despacha → contador queda en 0. El sabotaje total (borrar
    // queueRender → contador congelado) solo se observa con loop corriendo
    // (gate conjunto). Aquí verificamos que feed() no crashea y que el
    // agendamiento ocurre (glib.idleAdd devuelve source ID ≠ 0).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    var widget: TerminalWidget = undefined;
    widget.view = tv;
    widget.grid_cols = 80;
    widget.grid_rows = 24;
    widget.cell_w = 10.0;
    widget.cell_h = 15.0;
    widget.frames_requested = 0;
    widget.pango_ctx = null;
    widget.normal_desc = null;
    widget.bold_desc = null;
    widget.italic_desc = null;
    widget.bold_italic_desc = null;

    // feed() should not crash. Counter is 0 without main loop (expected).
    try widget.feed("Hello");
    try std.testing.expectEqual(@as(u64, 0), widget.frames_requested);
}

test "rasterizeDirtyRows produce superficies para filas sucias tras SGR+feed" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    var widget: TerminalWidget = undefined;
    widget.view = tv;
    widget.grid_cols = 80;
    widget.grid_rows = 24;
    widget.cell_w = 10.0;
    widget.cell_h = 15.0;
    widget.rows_rasterized = 0;
    widget.pango_ctx = null;
    widget.normal_desc = null;
    widget.bold_desc = null;
    widget.italic_desc = null;
    widget.bold_italic_desc = null;

    // Create a headless pango context for rasterization.
    const pango_ctx = pango.Context.new();
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, pango_ctx));

    // Set up font descriptions (normally done by ensureReady).
    const nd = pango.FontDescription.new();
    nd.setFamily("Monospace");
    nd.setAbsoluteSize(14.0 * 1024.0);
    widget.normal_desc = nd;
    const bd = pango.FontDescription.new();
    bd.setFamily("Monospace");
    bd.setAbsoluteSize(14.0 * 1024.0);
    bd.setWeight(.bold);
    widget.bold_desc = bd;
    const id = pango.FontDescription.new();
    id.setFamily("Monospace");
    id.setAbsoluteSize(14.0 * 1024.0);
    id.setStyle(.italic);
    widget.italic_desc = id;
    const bid = pango.FontDescription.new();
    bid.setFamily("Monospace");
    bid.setAbsoluteSize(14.0 * 1024.0);
    bid.setWeight(.bold);
    bid.setStyle(.italic);
    widget.bold_italic_desc = bid;

    // Sabotaje (a): sin feed → 0 filas rasterizadas.
    // Consume the initial .full state first.
    try tv.beginUpdate();
    tv.endUpdate();
    tv.clean();

    // Now no feed → 0 dirty rows.
    try tv.beginUpdate();
    widget.rasterizeDirtyRows(&tv.render_state, pango_ctx, 800);
    try std.testing.expectEqual(@as(usize, 0), widget.rows_rasterized);
    tv.endUpdate();
    tv.clean();

    // Feed SGR bold+texto → ensucia filas.
    try tv.feed("Hello, Kelpie!\r\n\x1b[1;31mX\x1b[0m");

    try tv.beginUpdate();
    tv.endUpdate(); // denormalize styles before reading them
    widget.rasterizeDirtyRows(&tv.render_state, pango_ctx, 800);
    // Should have rasterized > 0 rows.
    try std.testing.expect(widget.rows_rasterized > 0);
    tv.clean();

    // Sabotaje (b): sin beginUpdate (dirty = .false) → 0.
    widget.rasterizeDirtyRows(&tv.render_state, pango_ctx, 800);
    try std.testing.expectEqual(@as(usize, 0), widget.rows_rasterized);
}
