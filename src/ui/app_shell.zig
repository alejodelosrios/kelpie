//! App shell for kelpie (#13): an `adw.Application` opening a single window —
//! `adw.ToolbarView` (header 42px / status bar 24px) wrapping an `adw.OverlaySplitView`
//! (sidebar 260px fixed, `Ctrl+B` collapses it) with an empty-state label as content.
//! Territory: ui-builder. Same `adw.Application` + `gobject.ext.as` cast pattern as
//! `src/ui/spike_b.zig` (#3). See roadmap/designs/13-app-shell.md.
const std = @import("std");
const gobject = @import("gobject");
const glib = @import("glib");
const gio = @import("gio");
const gtk = @import("gtk");
const gdk = @import("gdk");
const adw = @import("adw");

const app_id = "io.github.alejodelosrios.kelpie";

const kelpie_css =
    "" ++
    ".kelpie-headerbar { min-height: 42px; }\n" ++
    ".kelpie-statusbar { min-height: 24px; }\n" ++
    ".kelpie-empty-label { font-size: 28px; font-weight: 300; }\n";

// Set once in run(), before gio.Application.run() hands control to GTK; read by
// onActivate(). Single instance, single thread — no synchronization needed.
var empty_state_text: [*:0]const u8 = "No agents";

/// Picks the empty-state label text by locale prefix (see design #13 §"No entra" —
/// no translation framework, just a `LANG`/`LC_ALL` prefix check).
fn emptyStateText(lang: []const u8) [*:0]const u8 {
    return if (std.mem.startsWith(u8, lang, "es")) "Sin agentes" else "No agents";
}

pub fn run(init: std.process.Init) u8 {
    const lang = init.environ_map.get("LANG") orelse init.environ_map.get("LC_ALL") orelse "";
    empty_state_text = emptyStateText(lang);

    const app = adw.Application.new(app_id, .{});
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, app));

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &onActivate, null, .{});

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), 0, null);
    return if (status < 0 or status > 255) 1 else @intCast(status);
}

fn onActivate(app: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    loadCss();

    const gtk_app = gobject.ext.as(gtk.Application, app);
    const window = adw.ApplicationWindow.new(gtk_app);
    gtk.Window.setDefaultSize(gobject.ext.as(gtk.Window, window), 1100, 700);
    gtk.Window.setTitle(gobject.ext.as(gtk.Window, window), "kelpie");

    const header = adw.HeaderBar.new();
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, header), "kelpie-headerbar");

    const status_bar = gtk.Box.new(.horizontal, 0);
    gtk.Widget.setSizeRequest(gobject.ext.as(gtk.Widget, status_bar), -1, 24);
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, status_bar), "kelpie-statusbar");

    const sidebar = gtk.Box.new(.vertical, 0);

    const empty_label = gtk.Label.new(empty_state_text);
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, empty_label), "kelpie-empty-label");
    gtk.Widget.setHalign(gobject.ext.as(gtk.Widget, empty_label), .center);
    gtk.Widget.setValign(gobject.ext.as(gtk.Widget, empty_label), .center);

    const split = adw.OverlaySplitView.new();
    adw.OverlaySplitView.setSidebar(split, gobject.ext.as(gtk.Widget, sidebar));
    adw.OverlaySplitView.setContent(split, gobject.ext.as(gtk.Widget, empty_label));
    adw.OverlaySplitView.setMinSidebarWidth(split, 260);
    adw.OverlaySplitView.setMaxSidebarWidth(split, 260);
    adw.OverlaySplitView.setSidebarWidthUnit(split, .px);

    const toolbar_view = adw.ToolbarView.new();
    adw.ToolbarView.addTopBar(toolbar_view, gobject.ext.as(gtk.Widget, header));
    adw.ToolbarView.addBottomBar(toolbar_view, gobject.ext.as(gtk.Widget, status_bar));
    adw.ToolbarView.setContent(toolbar_view, gobject.ext.as(gtk.Widget, split));

    adw.ApplicationWindow.setContent(window, gobject.ext.as(gtk.Widget, toolbar_view));

    addSidebarToggleShortcut(gobject.ext.as(gtk.Widget, window), split);

    gtk.Window.present(gobject.ext.as(gtk.Window, window));
}

fn loadCss() void {
    const display = gdk.Display.getDefault() orelse return;
    const provider = gtk.CssProvider.new();
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, provider));
    gtk.CssProvider.loadFromString(provider, kelpie_css);
    gtk.StyleContext.addProviderForDisplay(
        display,
        gobject.ext.as(gtk.StyleProvider, provider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

fn addSidebarToggleShortcut(widget: *gtk.Widget, split: *adw.OverlaySplitView) void {
    const trigger = gtk.ShortcutTrigger.parseString("<Control>b") orelse return;
    const action = gtk.CallbackAction.new(&toggleSidebar, @ptrCast(split), null);
    const shortcut = gtk.Shortcut.new(trigger, gobject.ext.as(gtk.ShortcutAction, action));
    const controller = gtk.ShortcutController.new();
    gtk.ShortcutController.addShortcut(controller, shortcut);
    gtk.Widget.addController(widget, gobject.ext.as(gtk.EventController, controller));
}

fn toggleSidebar(_: *gtk.Widget, _: ?*glib.Variant, user_data: ?*anyopaque) callconv(.c) c_int {
    const split: *adw.OverlaySplitView = @ptrCast(@alignCast(user_data.?));
    const shown = adw.OverlaySplitView.getShowSidebar(split);
    adw.OverlaySplitView.setShowSidebar(split, @intFromBool(shown == 0));
    return 1; // handled
}

test "emptyStateText picks Spanish for an es locale" {
    try std.testing.expectEqualStrings("Sin agentes", std.mem.span(emptyStateText("es")));
}

test "emptyStateText picks Spanish for a full es_MX.UTF-8 LANG value" {
    try std.testing.expectEqualStrings("Sin agentes", std.mem.span(emptyStateText("es_MX.UTF-8")));
}

test "emptyStateText picks English for en_US.UTF-8" {
    try std.testing.expectEqualStrings("No agents", std.mem.span(emptyStateText("en_US.UTF-8")));
}

test "emptyStateText picks English when LANG is empty" {
    try std.testing.expectEqualStrings("No agents", std.mem.span(emptyStateText("")));
}

test "emptyStateText does not match locales that merely contain es, only a leading prefix" {
    // "test_ES" doesn't start with "es" (case-sensitive, prefix check) — must fall back to English.
    try std.testing.expectEqualStrings("No agents", std.mem.span(emptyStateText("fr_es_FR")));
}
