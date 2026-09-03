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
const ThemeWatcher = @import("../omarchy/ThemeWatcher.zig");
const Store = @import("../model/Store.zig").Store;
const types = @import("../herdr/types.zig");
const LocalServer = @import("../herdr/LocalServer.zig");
const herdr_link = @import("herdr_link.zig");
const Sidebar = @import("sidebar.zig").Sidebar;
const attach = @import("../herdr/attach.zig");

const app_id = "io.github.alejodelosrios.kelpie";

/// Parsed subcommand from the command-line handler. Pure data — no GObject
/// dependency — so `parseCommand` is testable without a running application.
const Command = union(enum) {
    /// No subcommand (or empty argv): activate the primary instance.
    activate,
    /// `focus <device>/<pane>` — select an agent in the sidebar.
    focus: struct { device: []const u8, pane: []const u8 },
    /// `reload-theme` — re-read and apply the Omarchy theme CSS.
    reload_theme,
    /// `reload-font` — (not yet implemented, area:font).
    reload_font,
    /// Recognised subcommand with malformed arguments; `msg` is a static string.
    malformed: [*:0]const u8,
    /// Unrecognised subcommand name.
    unknown: [*:0]const u8,
};

/// Pure parser: takes a slice of UTF-8 strings (already spanned from `[*:0]u8`)
/// and returns the corresponding `Command`. No side effects, no allocations.
fn parseCommand(argv: []const []const u8) Command {
    if (argv.len == 0) return .activate;

    const subcmd = argv[0];
    // `main.zig` already consumed `--demo-sidebar[=N]` into `demo_sidebar_n`
    // before argv reaches here (real argv is forwarded to GIO so
    // G_APPLICATION_HANDLES_COMMAND_LINE works) — it's not a subcommand, just
    // a flag that arrived alongside a plain launch.
    if (std.mem.startsWith(u8, subcmd, "--demo-sidebar")) return .activate;
    if (std.mem.eql(u8, subcmd, "focus")) {
        if (argv.len < 2) return .{ .malformed = "focus: missing <device>/<pane> argument\n" };
        const target = argv[1];
        const slash_pos = std.mem.indexOfScalar(u8, target, '/');
        if (slash_pos == null or slash_pos.? == 0)
            return .{ .malformed = "focus: argument must be <device>/<pane>\n" };
        const pos = slash_pos.?;
        if (pos + 1 >= target.len)
            return .{ .malformed = "focus: pane part is empty\n" };
        return .{ .focus = .{
            .device = target[0..pos],
            .pane = target[pos + 1 ..],
        } };
    }
    if (std.mem.eql(u8, subcmd, "reload-theme")) return .reload_theme;
    if (std.mem.eql(u8, subcmd, "reload-font")) return .reload_font;

    return .{ .unknown = "unknown subcommand\n" };
}

pub const kelpie_css =
    "" ++
    ".kelpie-headerbar { min-height: 42px; }\n" ++
    ".kelpie-statusbar { min-height: 24px; }\n" ++
    ".kelpie-empty-label { font-size: 28px; font-weight: 300; }\n" ++
    // Sidebar rows (#16 design §"Widgets, métricas y CSS") — cero hex/rgb/hsl,
    // todo por var(--…) (ADR-0001 §5). Heights are the only metric in Zig.
    ".kelpie-row-device { min-height: 30px; }\n" ++
    ".kelpie-row-workspace { min-height: 30px; }\n" ++
    ".kelpie-row-agent { min-height: 28px; }\n" ++
    ".kelpie-sidebar-list row { background: transparent; }\n" ++
    ".kelpie-sidebar-list row:hover { background: var(--item-wash); }\n" ++
    ".kelpie-sidebar-list row:selected { background: var(--item-wash-selected); }\n" ++
    // Hairline SOLO entre grupos, e insertado: nada de rejilla de borde a borde.
    // El margen lateral va en la caja de la fila, no en el nodo `row`, para que
    // el wash de hover/selección siga llegando a los bordes.
    // La línea se inserta con un gradiente, no con `margin`: un margen movería
    // también el texto de la cabecera y la desalinearía de las filas de agente.
    ".kelpie-row-workspace {" ++
    " background-image: linear-gradient(to right," ++
    " transparent 12px, var(--hairline) 12px," ++
    " var(--hairline) calc(100% - 12px), transparent calc(100% - 12px));" ++
    " background-size: 100% 1px; background-repeat: no-repeat;" ++
    " background-position: top left; }\n" ++
    ".kelpie-row-title { color: var(--text-1); font-size: 13px; font-weight: 500; }\n" ++
    ".kelpie-row-subtitle { color: var(--text-2); font-size: 11.5px; }\n" ++
    ".kelpie-glyph-working { color: var(--status-working); }\n" ++
    // Glifos Nerd Font (U+F0026, U+F012C): la fuente de UI del sistema no los
    // tiene, así que sin font-family explícito se pinta un hueco.
    ".kelpie-glyph-blocked { color: var(--status-blocked); font-family: \"JetBrainsMono Nerd Font\", \"JetBrainsMono NF\", monospace; }\n" ++
    ".kelpie-glyph-done { color: var(--status-done); font-family: \"JetBrainsMono Nerd Font\", \"JetBrainsMono NF\", monospace; }\n";

// Set once in run(), before gio.Application.run() hands control to GTK; read by
// onActivate(). Single instance, single thread — no synchronization needed.
var empty_state_text: [*:0]const u8 = "No agents";

// Set once, before onActivate runs — same "set in run(), read in onActivate"
// pattern as empty_state_text. Defaults to page_allocator (not `undefined`)
// so unit tests that call `focusAgent` without ever calling `run()` — e.g.
// against an empty Store — get a real, usable allocator instead of garbage.
var gpa: std.mem.Allocator = std.heap.page_allocator;

// Saved from init.environ_map / init.io in run(), so onActivate can pass
// them to herdr_link.start().  Same "set once in run()" pattern as gpa.
var io: std.Io = undefined;
var environ_map: *std.process.Environ.Map = undefined;

// The Store (#12) and Sidebar (#16) this app owns. `store` needs no GTK/display
// and is built lazily the first time anything needs it (including from a
// `focus` command-line arriving before any `activate`); `sidebar`'s widget
// tree needs a live display, so it's only ever built from `onActivate`.
var store: Store = undefined;
var store_inited = false;
var sidebar: Sidebar = undefined;
var sidebar_inited = false;

// Herdr link (#81): owns the startup thread and EventsClient.
// Started once from onActivate, stopped from the shutdown signal.
var link: herdr_link.Link = .{};
var link_started: bool = false;

// Reference to the empty-state label widget, so the herdr_link startup
// thread can update its text once the server status is known.
var empty_label_ref: ?*gtk.Label = null;

/// `--demo-sidebar[=N]` (design #16 §"--demo-sidebar[=N]"): set by `main.zig`
/// before `run()`, read once by the first `onActivate`. `null` = no demo data.
pub var demo_sidebar_n: ?u32 = null;
var demo_sidebar_seeded = false;

// CssProviders: created and registered with the display once (first loadCss
// call); subsequent calls reuse the same providers and just reload the data.
// loadFromPath/loadFromString clear previous content, so the cascade updates
// in place without accumulating providers. Single thread — no sync.
var struct_provider: ?*gtk.CssProvider = null;
var theme_provider: ?*gtk.CssProvider = null;

// Watches $XDG_STATE_HOME/omarchy/current/ (or ~/.local/state/omarchy/current/)
// for theme changes and re-applies the CSS live (#15). Started once from
// onActivate, same single-thread/no-sync pattern as the providers above.
var theme_watcher: ThemeWatcher = .{};
var theme_watcher_started: bool = false;

/// Picks the empty-state label text by locale prefix (see design #13 §"No entra" —
/// no translation framework, just a `LANG`/`LC_ALL` prefix check).
/// Used only at startup (before the herdr link publishes the real status).
/// The real status-specific text arrives via the dispatcher trampoline,
/// which calls `emptyStateTextWithKind` directly.
fn emptyStateText(lang: []const u8) [*:0]const u8 {
    const is_es = std.mem.startsWith(u8, lang, "es");
    return if (is_es) "Sin agentes" else "No agents";
}

fn emptyStateTextWithKind(lang: []const u8, kind: LocalServer.Kind) [*:0]const u8 {
    const is_es = std.mem.startsWith(u8, lang, "es");
    return switch (kind) {
        .connected, .launched => if (is_es) "Sin agentes" else "No agents",
        .launch_timed_out => if (is_es) "herdr no respondio" else "herdr did not respond",
        .stopped_no_autostart => if (is_es) "herdr detenido" else "herdr stopped",
    };
}

pub fn run(init: std.process.Init) u8 {
    gpa = init.gpa;
    io = init.io;
    environ_map = init.environ_map;
    const lang = init.environ_map.get("LANG") orelse init.environ_map.get("LC_ALL") orelse "";
    empty_state_text = emptyStateText(lang);

    const app = adw.Application.new(app_id, .{ .handles_command_line = true });
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, app));

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &onActivate, null, .{});
    _ = gio.Application.signals.command_line.connect(app, ?*anyopaque, &onCommandLine, null, .{});
    _ = gio.Application.signals.shutdown.connect(app, ?*anyopaque, &onShutdown, null, .{});

    // Build real argv from init so GIO sends remaining args to the primary
    // instance (G_APPLICATION_HANDLES_COMMAND_LINE requires real argv — passing
    // argc=0/argv=null makes the feature inert).
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    var argv_buf: [16][*:0]u8 = undefined;
    const argc: c_int = @intCast(@min(args.len, argv_buf.len));
    for (0..@intCast(argc)) |i| {
        argv_buf[i] = @constCast(args[i].ptr);
    }

    const status = gio.Application.run(gobject.ext.as(gio.Application, app), argc, &argv_buf);
    return if (status < 0 or status > 255) 1 else @intCast(status);
}

fn onActivate(app: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    loadCss();

    // Idempotent: if the window already exists (e.g. command-line triggered
    // activate() after a focus command), just present it — don't create a duplicate.
    // Uses GTK's own accounting (getActiveWindow) instead of a global that could
    // become a dangling pointer if the window is destroyed between signals.
    const gtk_app = gobject.ext.as(gtk.Application, app);
    if (gtk.Application.getActiveWindow(gtk_app)) |w| {
        gtk.Window.present(w);
        return;
    }

    startThemeWatcherOnce();

    // Start herdr link (#81): connects to herdr, subscribes to events,
    // and wires callbacks that mutate the Store from the UI thread.
    startLinkOnce();

    const window = adw.ApplicationWindow.new(gtk_app);
    gtk.Window.setDefaultSize(gobject.ext.as(gtk.Window, window), 1100, 700);
    gtk.Window.setTitle(gobject.ext.as(gtk.Window, window), "kelpie");

    const header = adw.HeaderBar.new();
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, header), "kelpie-headerbar");

    const status_bar = gtk.Box.new(.horizontal, 0);
    gtk.Widget.setSizeRequest(gobject.ext.as(gtk.Widget, status_bar), -1, 24);
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, status_bar), "kelpie-statusbar");

    ensureSidebarInited();

    const empty_label = gtk.Label.new(empty_state_text);
    empty_label_ref = empty_label;
    // `empty_label_ref` es un puntero crudo sin referencia tomada, y el
    // trampolín que lo usa puede encolarse hasta ~13 s después (lo que tarde
    // `ensureRunning`). En ese hueco el usuario puede cerrar la ventana: GTK4
    // destruye la ApplicationWindow en `close-request` y finaliza la label con
    // ella. Sin esto, la fuente idle escribiría sobre memoria liberada.
    // Hoy no explota porque el quit de `g_application_release` va a
    // G_PRIORITY_DEFAULT y gana a G_PRIORITY_DEFAULT_IDLE — pero eso es una
    // ordenación de prioridades de GLib que nadie verificó, no una garantía
    // del diseño. Es el mismo razonamiento de "quién posee qué y cuándo" que
    // se quitó del dispatcher; aquí también se quita.
    _ = gtk.Widget.signals.destroy.connect(
        gobject.ext.as(gtk.Widget, empty_label),
        ?*anyopaque,
        &onEmptyLabelDestroy,
        null,
        .{},
    );
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, empty_label), "kelpie-empty-label");
    gtk.Widget.setHalign(gobject.ext.as(gtk.Widget, empty_label), .center);
    gtk.Widget.setValign(gobject.ext.as(gtk.Widget, empty_label), .center);

    const split = adw.OverlaySplitView.new();
    adw.OverlaySplitView.setSidebar(split, sidebar.widget);
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

/// GApplication command-line handler. Receives remote invocations (e.g.
/// `kelpie focus local/pane1`) and dispatches them to the appropriate action.
///
/// Return value: the exit status (0 = success, 1 = error). GIO passes this
/// value to `ApplicationCommandLine.setExitStatus` after the handler returns
/// (gio2.zig:2025-2029, gio.Application.signals.command-line documentation),
/// so the return value IS the real exit status — we must not hardcode 0.
fn onCommandLine(app: *adw.Application, cmdline: *gio.ApplicationCommandLine, _: ?*anyopaque) callconv(.c) c_int {
    var status: c_int = 0;

    var argc: c_int = 0;
    const argv_raw = gio.ApplicationCommandLine.getArguments(cmdline, &argc);
    defer glib.strfreev(@ptrCast(argv_raw));
    // argv_raw is [*][*:0]u8, NULL-terminated. argc includes the program name.
    // Convert to [][]const u8 for the pure parser (skip argv[0] = program name).
    const count: usize = @intCast(argc);
    if (count < 2) {
        // No subcommand: just activate the primary instance.
        gio.Application.activate(gobject.ext.as(gio.Application, app));
        gio.ApplicationCommandLine.setExitStatus(cmdline, status);
        return status;
    }

    // Build a slice of []const u8 from argv[1..argc] for parseCommand.
    var args_buf: [16][]const u8 = undefined;
    const arg_count = @min(count - 1, args_buf.len);
    for (0..arg_count) |i| {
        args_buf[i] = std.mem.span(argv_raw[i + 1]);
    }
    const cmd = parseCommand(args_buf[0..arg_count]);

    switch (cmd) {
        .activate => {
            gio.Application.activate(gobject.ext.as(gio.Application, app));
        },
        .focus => |f| {
            if (focusAgent(f.device, f.pane)) {
                gio.Application.activate(gobject.ext.as(gio.Application, app));
                // Present the window and select the row (focusAgent already did
                // the selection if the sidebar existed; activate() above builds
                // it if this was the first invocation, but doesn't re-select).
                const gtk_app = gobject.ext.as(gtk.Application, app);
                if (gtk.Application.getActiveWindow(gtk_app)) |w| {
                    gtk.Window.present(w);
                    if (sidebar_inited) _ = sidebar.selectByKey(f.device, f.pane);
                }
            } else {
                cmdline.printerrLiteral("focus: agente no encontrado\n");
                status = 1;
            }
        },
        .reload_theme => {
            reloadTheme();
        },
        .reload_font => {
            // ponytail: area:font has not been started yet. The command arrives,
            // dispatches, and responds with an explicit warning — nothing more.
            cmdline.printerrLiteral("reload-font: no implementado (area:font)\n");
        },
        .malformed => |msg| {
            cmdline.printerrLiteral(msg);
            status = 1;
        },
        .unknown => |msg| {
            cmdline.printerrLiteral(msg);
            status = 1;
        },
    }
    gio.ApplicationCommandLine.setExitStatus(cmdline, status);
    return status;
}

/// Backed by the real Store (#16): true if `(device, pane)` exists as an
/// agent. `ensureStoreInited` guarantees the Store exists even if this is
/// the process's first invocation (a `focus` command-line call can arrive
/// before any `activate`/window — no GTK/display needed for this). When the
/// sidebar widget also happens to exist already, this additionally selects
/// the row. The actual "switch herdr to this pane" action is #19 (attach) —
/// out of scope here (design #16 §"No entra").
fn focusAgent(device: []const u8, pane: []const u8) bool {
    ensureStoreInited();
    const found = store.agents.contains(.{ .device_id = device, .pane_id = pane });
    if (found and sidebar_inited) _ = sidebar.selectByKey(device, pane);
    return found;
}

/// Builds the Store once (idempotent, same pattern as
/// `startThemeWatcherOnce`) — no GTK/display dependency, safe to call from a
/// headless command-line invocation or a unit test.
fn ensureStoreInited() void {
    if (store_inited) return;
    store_inited = true;
    store = Store.init(gpa);
}

/// Starts the herdr link once (idempotent).  Safe to call from onActivate
/// — the startup thread may block for ~10 s in ensureRunning, but that
/// doesn't hang the UI because it's in its own thread.
fn startLinkOnce() void {
    if (link_started) return;
    link_started = true;
    ensureStoreInited();

    // Register the callback so the startup thread's trampoline can
    // update the empty-state label from the UI thread.
    herdr_link.updateStatusLabel = &onStatusLabelUpdate;

    link.start(gpa, io, environ_map, &store);
}

/// La label murió con su ventana: el puntero crudo deja de ser válido.
fn onEmptyLabelDestroy(_: *gtk.Widget, _: ?*anyopaque) callconv(.c) void {
    empty_label_ref = null;
}

/// Called from the herdr_link trampoline (UI thread) once the startup
/// thread has determined the server status.  Updates the empty-state
/// label text to explain why there are no agents.
fn onStatusLabelUpdate(kind: LocalServer.Kind) void {
    if (empty_label_ref) |label| {
        const lang = environ_map.get("LANG") orelse environ_map.get("LC_ALL") orelse "";
        const text = emptyStateTextWithKind(lang, kind);
        gtk.Label.setLabel(label, text);
    }
}

/// GApplication shutdown handler: stops the herdr link (joins startup
/// thread, stops EventsClient) before the main loop exits.
fn onShutdown(_: *adw.Application, _: ?*anyopaque) callconv(.c) void {
    link.stop();
}

/// Builds the Sidebar widget once `ensureStoreInited` has run, registers it
/// as a `ChangeObserver`, and seeds `--demo-sidebar[=N]` synthetic data the
/// first time it runs. Needs a live display — only called from `onActivate`.
fn ensureSidebarInited() void {
    ensureStoreInited();
    if (sidebar_inited) return;
    sidebar_inited = true;

    sidebar.init(gpa, &store);
    sidebar.setFocusCallback(&onSidebarActivated, null);
    store.addObserver(sidebar.observer()) catch |err| {
        std.log.err("sidebar: addObserver failed: {t}", .{err});
    };

    seedDemoSidebarOnce();
}

/// Row activation from a click (`gtk.ListView`'s single-click-activate,
/// criterio 6). Spawns the external attach on a detached thread — never
/// blocks the GTK main loop.
fn onSidebarActivated(_: ?*anyopaque, device: []const u8, pane: []const u8) void {
    _ = device; // not used this round — TARGET is just the pane

    // `pane` is a borrowed slice from Sidebar.rows; a concurrent refresh()
    // can free it while the attach thread is still running.  Duplicate it
    // so the thread owns its copy.
    const pane_owned = gpa.dupe(u8, pane) catch |err| {
        std.log.err("attach: dupe pane failed: {t}", .{err});
        return;
    };

    // Compat check + spawn in a detached thread — never block the GTK main loop.
    const thread = std.Thread.spawn(.{}, attachThreadFn, .{pane_owned}) catch |err| {
        std.log.err("attach: failed to spawn thread: {t}", .{err});
        gpa.free(pane_owned);
        return;
    };
    thread.detach();
}

/// Runs in a detached thread: checks protocol compat and spawns the attach
/// process.  Owns `pane` and frees it on exit.
fn attachThreadFn(pane: []const u8) void {
    defer gpa.free(pane);
    attach.attachOrLogMismatch(io, gpa, environ_map.*, pane);
}

/// Re-applies the theme CSS. Callable from both `onActivate` (startup) and
/// the `reload-theme` command-line subcommand.
fn reloadTheme() void {
    loadCss();
}

// ---------------------------------------------------------------------------
// --demo-sidebar[=N] (#16 design §"--demo-sidebar[=N]"): criterios 1, 2 y 5
// exigen mirar y medir un sidebar poblado, y sin el cableado a herdr (#81,
// fuera de alcance de #16) nada lo puebla en uso normal. This seeds a
// synthetic snapshot of N agents (default 4) in 2 workspaces, all idle, and
// arms a one-shot 2s timer that flips one to blocked via applyEvent — the
// instrument the three criteria need, behind the flag, never touched by a
// normal start.
// ---------------------------------------------------------------------------

const demo_blocked_pane = "pane-0";
const demo_blocked_workspace = "ws-a";

fn seedDemoSidebarOnce() void {
    if (demo_sidebar_seeded) return;
    const n = demo_sidebar_n orelse return;
    demo_sidebar_seeded = true;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workspaces_buf = arena.alloc(types.WorkspaceInfo, 2) catch |err| {
        std.log.err("--demo-sidebar: alloc failed: {t}", .{err});
        return;
    };
    workspaces_buf[0] = .{
        .workspace_id = "ws-a",
        .number = 1,
        .label = "Workspace A",
        .focused = true,
        .pane_count = 0,
        .tab_count = 0,
        .active_tab_id = "",
        .agent_status = .idle,
    };
    workspaces_buf[1] = .{
        .workspace_id = "ws-b",
        .number = 2,
        .label = "Workspace B",
        .focused = false,
        .pane_count = 0,
        .tab_count = 0,
        .active_tab_id = "",
        .agent_status = .idle,
    };

    const agents = arena.alloc(types.AgentInfo, n) catch |err| {
        std.log.err("--demo-sidebar: alloc failed: {t}", .{err});
        return;
    };
    for (agents, 0..) |*a, i| {
        const ws: []const u8 = if (i % 2 == 0) "ws-a" else "ws-b";
        const pane_id = std.fmt.allocPrint(arena, "pane-{d}", .{i}) catch |err| {
            std.log.err("--demo-sidebar: alloc failed: {t}", .{err});
            return;
        };
        a.* = .{
            .terminal_id = pane_id,
            .agent_status = .idle,
            .workspace_id = ws,
            .tab_id = "tab-1",
            .pane_id = pane_id,
            .focused = false,
            .revision = @intCast(i + 1),
            .agent = "claude",
            .cwd = "~/kelpie",
        };
    }

    store.applySnapshot(.{
        .version = "1",
        .protocol = 1,
        .workspaces = workspaces_buf,
        .tabs = &.{},
        .panes = &.{},
        .layouts = &.{},
        .agents = agents,
    }) catch |err| {
        std.log.err("--demo-sidebar: applySnapshot failed: {t}", .{err});
        return;
    };

    if (n > 0) {
        _ = glib.timeoutAddOnce(2000, &onDemoBlockTimer, null);
    }
}

fn onDemoBlockTimer(_: ?*anyopaque) callconv(.c) void {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(gpa);
    obj.put(gpa, "pane_id", .{ .string = demo_blocked_pane }) catch |err| {
        std.log.err("--demo-sidebar: timer failed: {t}", .{err});
        return;
    };
    obj.put(gpa, "workspace_id", .{ .string = demo_blocked_workspace }) catch |err| {
        std.log.err("--demo-sidebar: timer failed: {t}", .{err});
        return;
    };
    obj.put(gpa, "agent_status", .{ .string = "blocked" }) catch |err| {
        std.log.err("--demo-sidebar: timer failed: {t}", .{err});
        return;
    };
    store.applyEvent(.{ .event = .pane_agent_status_changed, .data = .{ .object = obj } }) catch |err| {
        std.log.err("--demo-sidebar: applyEvent failed: {t}", .{err});
    };
}

fn loadCss() void {
    const display = gdk.Display.getDefault() orelse return;

    // 1. Structural CSS (heights, typography) — always from the embedded constant.
    if (struct_provider == null) {
        struct_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            gobject.ext.as(gtk.StyleProvider, struct_provider.?),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
    gtk.CssProvider.loadFromString(struct_provider.?, kelpie_css);

    // 2. Theme CSS (colors) — from Omarchy's generated file or embedded fallback.
    if (theme_provider == null) {
        theme_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            gobject.ext.as(gtk.StyleProvider, theme_provider.?),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (findThemeCssPath(&path_buf)) |path| {
        gtk.CssProvider.loadFromPath(theme_provider.?, path);
    } else {
        const fallback_css: [*:0]const u8 = @embedFile("kelpie-fallback-css");
        gtk.CssProvider.loadFromString(theme_provider.?, fallback_css);
        std.log.warn("theme CSS not found, using fallback", .{});
    }
}

/// Returns the path to `~/.local/state/omarchy/current/theme/kelpie.css`
/// (or `$XDG_STATE_HOME/omarchy/current/theme/kelpie.css` if set),
/// or null if the file doesn't exist. The returned pointer lives inside `buf`,
/// which must outlive it (`loadCss` keeps its own `path_buf` on the stack for this).
fn findThemeCssPath(buf: *[std.fs.max_path_bytes]u8) ?[*:0]const u8 {
    const state_home = std.c.getenv("XDG_STATE_HOME");
    const path = if (state_home) |sh|
        std.fmt.bufPrintZ(buf, "{s}/omarchy/current/theme/kelpie.css", .{std.mem.span(sh)}) catch return null
    else blk: {
        const home = std.c.getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrintZ(buf, "{s}/.local/state/omarchy/current/theme/kelpie.css", .{std.mem.span(home)}) catch return null;
    };

    // Check if the file exists
    const file = gio.File.newForPath(path);
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, file));
    if (gio.File.queryExists(file, null) == 0) {
        return null;
    }

    return path;
}

/// Arms the theme watcher once, on the `current/` directory (same
/// $XDG_STATE_HOME/HOME resolution as `findThemeCssPath`, one level up from
/// the CSS file itself — the watcher needs the directory Omarchy replaces
/// wholesale, not the file). Idempotent: onActivate can run again (e.g. a
/// second `activate` signal) without re-arming.
fn startThemeWatcherOnce() void {
    if (theme_watcher_started) return;
    theme_watcher_started = true;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (findThemeCurrentDir(&dir_buf)) |dir| {
        theme_watcher.start(dir, &onThemeWatcherReload, null);
    }
}

fn onThemeWatcherReload(_: ?*anyopaque) void {
    reloadTheme();
}

/// Returns `$XDG_STATE_HOME/omarchy/current` (or
/// `~/.local/state/omarchy/current` if unset) — the directory
/// `omarchy-theme-set` replaces wholesale (`rm -rf` + `mv`). Unlike
/// `findThemeCssPath`, does not check existence: `ThemeWatcher.start` already
/// tolerates a directory that doesn't exist yet (design #15 "Riesgos").
fn findThemeCurrentDir(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const state_home = std.c.getenv("XDG_STATE_HOME");
    if (state_home) |sh|
        return std.fmt.bufPrint(buf, "{s}/omarchy/current", .{std.mem.span(sh)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/omarchy/current", .{std.mem.span(home)}) catch null;
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

// ThemeWatcher.zig has a consumer in this file (startThemeWatcherOnce), so
// its tests don't need a build.zig entry of their own (see design #15 §"No
// toca build.zig") — this makes them run under `zig build test` the same
// way main.zig's `test { _ = app_shell; }` already runs this file's tests.
test {
    _ = ThemeWatcher;
    _ = herdr_link;
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

// --- emptyStateTextWithKind tests (design #81) ---

test "emptyStateTextWithKind: .launch_timed_out in English" {
    try std.testing.expectEqualStrings("herdr did not respond", std.mem.span(emptyStateTextWithKind("en_US.UTF-8", .launch_timed_out)));
}

test "emptyStateTextWithKind: .launch_timed_out in Spanish" {
    try std.testing.expectEqualStrings("herdr no respondio", std.mem.span(emptyStateTextWithKind("es", .launch_timed_out)));
}

test "emptyStateTextWithKind: .stopped_no_autostart in English" {
    try std.testing.expectEqualStrings("herdr stopped", std.mem.span(emptyStateTextWithKind("en", .stopped_no_autostart)));
}

test "emptyStateTextWithKind: .stopped_no_autostart in Spanish" {
    try std.testing.expectEqualStrings("herdr detenido", std.mem.span(emptyStateTextWithKind("es_MX.UTF-8", .stopped_no_autostart)));
}

test "emptyStateTextWithKind: .connected defaults to No agents" {
    try std.testing.expectEqualStrings("No agents", std.mem.span(emptyStateTextWithKind("", .connected)));
}

test "emptyStateTextWithKind: .launched defaults to No agents" {
    try std.testing.expectEqualStrings("No agents", std.mem.span(emptyStateTextWithKind("", .launched)));
}

// --- parseCommand tests ---

test "parseCommand: empty argv returns activate" {
    const cmd = parseCommand(&.{});
    try std.testing.expectEqual(Command.activate, cmd);
}

test "parseCommand: --demo-sidebar (bare or with =N) activates instead of erroring as unknown" {
    // Real bug this pins: with .handles_command_line = true, GIO forwards the
    // full argv (including flags main.zig already consumed) to onCommandLine
    // -> parseCommand. Before this fix, `--demo-sidebar` fell through to
    // `.unknown`, so `kelpie --demo-sidebar` exited 1 instead of opening a
    // window — the exact instrument criterios 1/2/5 need never ran.
    try std.testing.expectEqual(Command.activate, parseCommand(&.{"--demo-sidebar"}));
    try std.testing.expectEqual(Command.activate, parseCommand(&.{"--demo-sidebar=200"}));
}

test "parseCommand: focus with valid device/pane" {
    const cmd = parseCommand(&.{ "focus", "local/p1" });
    try std.testing.expect(cmd == .focus);
    try std.testing.expectEqualStrings("local", cmd.focus.device);
    try std.testing.expectEqualStrings("p1", cmd.focus.pane);
}

test "parseCommand: focus with multi-char device and pane" {
    const cmd = parseCommand(&.{ "focus", "my-laptop/terminal-3" });
    try std.testing.expect(cmd == .focus);
    try std.testing.expectEqualStrings("my-laptop", cmd.focus.device);
    try std.testing.expectEqualStrings("terminal-3", cmd.focus.pane);
}

test "parseCommand: focus missing argument is malformed" {
    const cmd = parseCommand(&.{"focus"});
    try std.testing.expect(cmd == .malformed);
}

test "parseCommand: focus without slash is malformed" {
    const cmd = parseCommand(&.{ "focus", "noslash" });
    try std.testing.expect(cmd == .malformed);
}

test "parseCommand: focus with leading slash (empty device) is malformed" {
    const cmd = parseCommand(&.{ "focus", "/pane" });
    try std.testing.expect(cmd == .malformed);
}

test "parseCommand: focus with trailing slash (empty pane) is malformed" {
    const cmd = parseCommand(&.{ "focus", "device/" });
    try std.testing.expect(cmd == .malformed);
}

test "parseCommand: reload-theme" {
    const cmd = parseCommand(&.{"reload-theme"});
    try std.testing.expectEqual(Command.reload_theme, cmd);
}

test "parseCommand: reload-font" {
    const cmd = parseCommand(&.{"reload-font"});
    try std.testing.expectEqual(Command.reload_font, cmd);
}

test "parseCommand: unknown subcommand" {
    const cmd = parseCommand(&.{"dance"});
    try std.testing.expect(cmd == .unknown);
}

test "parseCommand: focus missing argument message names the expected form" {
    const cmd = parseCommand(&.{"focus"});
    try std.testing.expectEqualStrings("focus: missing <device>/<pane> argument\n", std.mem.span(cmd.malformed));
}

test "parseCommand: focus without slash message names the expected form" {
    const cmd = parseCommand(&.{ "focus", "noslash" });
    try std.testing.expectEqualStrings("focus: argument must be <device>/<pane>\n", std.mem.span(cmd.malformed));
}

test "parseCommand: focus with empty pane after slash message mentions pane" {
    // "device/" — slash present, pane part is empty. Distinct malformed message
    // from the missing-slash case; a builder could accidentally reuse the wrong
    // static string here, so pin the exact text.
    const cmd = parseCommand(&.{ "focus", "device/" });
    try std.testing.expectEqualStrings("focus: pane part is empty\n", std.mem.span(cmd.malformed));
}

// --- focusAgent (criterio 1/3 del diseño #17, backed by the real Store since #16) ---

test "focusAgent: a pane no test ever seeds reports not-found" {
    // `store`/`sidebar_inited` are process-wide globals and zig's test
    // runner reorders tests, so this only assumes "no other test ever seeds
    // a pane named this" — not that the Store is empty.
    try std.testing.expect(!focusAgent("local", "no-existe"));
    try std.testing.expect(!focusAgent("", ""));
}

test "focusAgent: an agent actually present in the Store is found" {
    // Proves the seam is real (Store-backed), not the old always-false stub:
    // deleting the `store.agents.contains(...)` call in focusAgent (and
    // reverting to `return false`) makes this fail while the not-found test
    // above keeps passing.
    ensureStoreInited();
    try store.applySnapshot(.{
        .version = "1",
        .protocol = 1,
        .workspaces = &.{},
        .tabs = &.{},
        .panes = &.{},
        .layouts = &.{},
        .agents = &.{.{
            .terminal_id = "p1",
            .agent_status = .idle,
            .workspace_id = "ws-a",
            .tab_id = "tab-1",
            .pane_id = "p1",
            .focused = false,
            .revision = 1,
        }},
    });
    try std.testing.expect(focusAgent("local", "p1"));
    try std.testing.expect(!focusAgent("local", "p2"));
}

// Scenario "focus con un pane conocido inyectado por el seam de test" (criterio 1)
// cannot be exercised as a pure unit test without either (a) mocking D-Bus/GIO,
// which the design explicitly forbids, or (b) temporarily patching focusAgent's
// body to return true and driving a real second `kelpie focus local/<pane>`
// invocation against a running primary instance. There is no test-only
// injection point in production code today (focusAgent takes no override and
// the design doesn't ask for one — see #17 "Riesgos", condición 3). QA cannot
// add that seam without touching production logic, which is Apply's job, not
// QA's. This scenario is therefore reported below as a manual gate, not
// skipped.
