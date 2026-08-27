//! Entry point for `kelpie --spike-b` (#3): boots an `adw.Application` with two
//! windows — the Pango/GSK text grid (plan A) and a bare `gtk.GLArea` (plan B) — per
//! roadmap/designs/3-spike-b-gtk4-pango.md.
const std = @import("std");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");
const grid_widget = @import("grid_widget.zig");

// gtk.GLArea::render clears the framebuffer with raw GL calls — there is no gobject
// binding for these (they're plain OpenGL, not a GDK/GTK wrapper). Declared as extern
// "c" and linked via `exe.linkSystemLibrary("GL")` in build.zig (see design "Riesgos"),
// not a new zig-pkg dependency.
extern "c" fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
extern "c" fn glClear(mask: c_uint) void;
const gl_color_buffer_bit: c_uint = 0x00004000;

pub fn run() void {
    const app = adw.Application.new("dev.kelpie.SpikeB", .{});
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, app));

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &onActivate, null, .{});

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), 0, null);
    std.debug.print("spike-b: exited with status {d}\n", .{status});
}

fn onActivate(app: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    const gtk_app = gobject.ext.as(gtk.Application, app);

    const grid_window = adw.ApplicationWindow.new(gtk_app);
    gtk.Window.setDefaultSize(gobject.ext.as(gtk.Window, grid_window), 1200, 900);
    const grid = grid_widget.GridWidget.new();
    adw.ApplicationWindow.setContent(grid_window, grid.as(gtk.Widget));
    gtk.Window.present(gobject.ext.as(gtk.Window, grid_window));

    const gl_window = adw.ApplicationWindow.new(gtk_app);
    gtk.Window.setDefaultSize(gobject.ext.as(gtk.Window, gl_window), 400, 300);
    const gl_area = gtk.GLArea.new();
    gtk.Widget.setSizeRequest(gobject.ext.as(gtk.Widget, gl_area), 400, 300);
    _ = gtk.GLArea.signals.render.connect(gl_area, ?*anyopaque, &onGlRender, null, .{});
    adw.ApplicationWindow.setContent(gl_window, gobject.ext.as(gtk.Widget, gl_area));
    gtk.Window.present(gobject.ext.as(gtk.Window, gl_window));
}

fn onGlRender(_: *gtk.GLArea, ctx: *gdk.GLContext, _: ?*anyopaque) callconv(.c) c_int {
    gdk.GLContext.makeCurrent(ctx);
    glClearColor(0.1, 0.2, 0.35, 1.0);
    glClear(gl_color_buffer_bit);
    return 1; // handled
}
