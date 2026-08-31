//! Sidebar (#16): espacios y agentes agrupados por urgencia, glifos de estado,
//! filas de 28/30 px y hairlines. Territorio: ui-builder. No habla con herdr —
//! recibe un `*Store` (#12), se registra como `ChangeObserver` y reconstruye su
//! modelo cuando el Store cambia. `app_shell.zig` (#13) crea el `Store`, monta
//! este widget en el slot del split y conecta `focusAgent` de verdad.
//! See roadmap/designs/16-sidebar-urgencia.md.
const std = @import("std");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");

const store_mod = @import("../model/Store.zig");
const Store = store_mod.Store;
const Agent = store_mod.Agent;
const types = @import("../herdr/types.zig");

// ---------------------------------------------------------------------------
// Row / RowKind — pure data, no GObject dependency. `buildRows` is testable
// with a plain `Store` and `std.testing.allocator`, no live GtkWidget needed.
// ---------------------------------------------------------------------------

pub const RowKind = enum { device, workspace, agent };

pub const Row = struct {
    kind: RowKind,
    status: types.AgentStatus,
    title: [:0]u8,
    subtitle: ?[:0]u8,
    device: []u8,
    pane: []u8,
};

pub fn freeRows(gpa: std.mem.Allocator, rows: []Row) void {
    for (rows) |row| {
        gpa.free(row.title);
        if (row.subtitle) |s| gpa.free(s);
        gpa.free(row.device);
        gpa.free(row.pane);
    }
    gpa.free(rows);
}

/// One workspace's agents, in the order they were first seen while walking
/// `Store.orderedAgents` (already sorted by urgency) — a stable group-by in
/// a single pass, no re-sorting (design §Agrupado).
const Group = struct {
    device_id: []const u8,
    workspace_id: []const u8,
    agents: std.array_list.Managed(*const Agent),
};

/// Builds the flat row list: `.device` ("local"), then per workspace a
/// `.workspace` row followed by its `.agent` rows — spaces ordered by their
/// most urgent agent, agents already urgency-ordered within each space
/// (`Store.orderedAgents`, `Store.zig:538`). A workspace with zero agents
/// never appears: the tree is derived from the agent list, not from
/// `store.workspaces` (design §"No entra" — "es un sidebar de agentes").
pub fn buildRows(gpa: std.mem.Allocator, store: *Store) ![]Row {
    var ordered = try store.orderedAgents(gpa);
    defer ordered.deinit();

    if (ordered.items.len == 0) return gpa.alloc(Row, 0);

    var groups = std.array_list.Managed(Group).init(gpa);
    defer {
        for (groups.items) |*g| g.agents.deinit();
        groups.deinit();
    }

    for (ordered.items) |agent| {
        var found: ?*Group = null;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.device_id, agent.device_id) and
                std.mem.eql(u8, g.workspace_id, agent.workspace_id))
            {
                found = g;
                break;
            }
        }
        if (found) |g| {
            try g.agents.append(agent);
        } else {
            var group = Group{
                .device_id = agent.device_id,
                .workspace_id = agent.workspace_id,
                .agents = std.array_list.Managed(*const Agent).init(gpa),
            };
            try group.agents.append(agent);
            try groups.append(group);
        }
    }

    var rows = std.array_list.Managed(Row).init(gpa);
    errdefer {
        for (rows.items) |row| {
            gpa.free(row.title);
            if (row.subtitle) |s| gpa.free(s);
            gpa.free(row.device);
            gpa.free(row.pane);
        }
        rows.deinit();
    }

    // Exactly one device in M1 ("local") — see design §"No entra" on why this
    // is a plain row, not a `gtk.SectionModel` section.
    try rows.ensureUnusedCapacity(1);
    rows.appendAssumeCapacity(try makeRow(gpa, .device, .idle, "local", null, "local", ""));

    for (groups.items) |g| {
        // The aggregated status IS the first agent's status in this group —
        // the group's first entry is its most urgent because the source list
        // is already globally urgency-sorted (design §Agrupado).
        const ws_status = g.agents.items[0].status;
        const ws_title: []const u8 = if (store.workspaces.getPtr(.{
            .device_id = g.device_id,
            .workspace_id = g.workspace_id,
        })) |info| info.label else g.workspace_id;

        try rows.ensureUnusedCapacity(1);
        rows.appendAssumeCapacity(try makeRow(gpa, .workspace, ws_status, ws_title, null, g.device_id, ""));

        for (g.agents.items) |agent| {
            try rows.ensureUnusedCapacity(1);
            const subtitle = try buildSubtitle(gpa, agent);
            rows.appendAssumeCapacity(try makeRow(
                gpa,
                .agent,
                agent.status,
                agent.displayTitle(),
                subtitle,
                agent.device_id,
                agent.pane_id,
            ));
        }
    }

    return rows.toOwnedSlice();
}

/// Builds one `Row`, duplicating `title`/`device`/`pane` with `gpa` and taking
/// ownership of an already-built `subtitle` (built by the caller, since only
/// `.agent` rows have one). A struct literal with several fallible fields
/// isn't atomic (result-location semantics write earlier fields before a
/// later `try` can fail) — this repo has hit that root cause before
/// (`Connection.open`, `openLive`, `request()` in the `zig-libghostty` skill).
/// Here the destination is a temporary the caller discards on error, so a
/// failure only leaks 1-3 allocations under OOM — not the UB those three
/// were — but each `errdefer` below still cleans up what came before it.
fn makeRow(
    gpa: std.mem.Allocator,
    kind: RowKind,
    status: types.AgentStatus,
    title: []const u8,
    subtitle: ?[:0]u8,
    device: []const u8,
    pane: []const u8,
) !Row {
    errdefer if (subtitle) |s| gpa.free(s);

    const title_z = try gpa.dupeZ(u8, title);
    errdefer gpa.free(title_z);

    const device_dup = try gpa.dupe(u8, device);
    errdefer gpa.free(device_dup);

    const pane_dup = try gpa.dupe(u8, pane);
    errdefer gpa.free(pane_dup);

    return .{
        .kind = kind,
        .status = status,
        .title = title_z,
        .subtitle = subtitle,
        .device = device_dup,
        .pane = pane_dup,
    };
}

/// "agente · cwd" (design table, fila `.agent`) — either half may be absent;
/// join what's there, or `null` if neither is.
fn buildSubtitle(gpa: std.mem.Allocator, agent: *const Agent) !?[:0]u8 {
    const name = agent.display_agent orelse agent.agent;
    const cwd = agent.cwd;
    if (name != null and cwd != null) {
        return try std.fmt.allocPrintSentinel(gpa, "{s} · {s}", .{ name.?, cwd.? }, 0);
    }
    if (name orelse cwd) |only| return try gpa.dupeZ(u8, only);
    return null;
}

// ---------------------------------------------------------------------------
// Glyph selection — pure mapping from status to what `AgentStatusGlyph` draws.
// Criterio 3 ("el spinner solo existe mientras el estado es working") holds by
// construction: the widget builder below only ever creates the glyph named
// here, never a hidden/invisible one.
// ---------------------------------------------------------------------------

pub const GlyphKind = enum { none, spinner, blocked, done };

pub fn glyphKindForStatus(status: types.AgentStatus) GlyphKind {
    return switch (status) {
        .working => .spinner,
        .blocked => .blocked,
        .done => .done,
        .idle, .unknown => .none,
    };
}

// ---------------------------------------------------------------------------
// RowObject — GObject mínimo para el gio.ListStore. Solo un índice a
// `Sidebar.rows`: sin punteros propios, sin finalize, sin duplicar strings —
// el dueño de los datos es el Sidebar (design §"Modelo de filas").
// ---------------------------------------------------------------------------

pub const RowObject = extern struct {
    parent_instance: Parent,
    index: u32,

    pub const Parent = gobject.Object;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        pub const Instance = RowObject;
    };
    pub const getGObjectType = gobject.ext.defineClass(RowObject, .{});

    pub fn new() *RowObject {
        return gobject.ext.newInstance(RowObject, .{});
    }
};

// ---------------------------------------------------------------------------
// Sidebar — owns the Store-derived `rows`, the GTK model/selection/view, and
// the widget tree embedded by `app_shell.zig` in the split view's sidebar
// slot.
// ---------------------------------------------------------------------------

pub const FocusFn = *const fn (data: ?*anyopaque, device: []const u8, pane: []const u8) void;

pub const Sidebar = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    rows: []Row = &.{},

    list_store: *gio.ListStore = undefined,
    selection: *gtk.SingleSelection = undefined,
    /// The `gtk.ScrolledWindow`, ready to hand to `adw.OverlaySplitView.setSidebar`.
    widget: *gtk.Widget = undefined,

    on_focus: ?FocusFn = null,
    on_focus_data: ?*anyopaque = null,

    pub fn init(self: *Sidebar, gpa: std.mem.Allocator, store: *Store) void {
        self.gpa = gpa;
        self.store = store;
        self.rows = &.{};
        self.on_focus = null;
        self.on_focus_data = null;

        self.list_store = gio.ListStore.new(RowObject.getGObjectType());
        self.selection = gtk.SingleSelection.new(gobject.ext.as(gio.ListModel, self.list_store));
        gtk.SingleSelection.setAutoselect(self.selection, 0);

        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Sidebar, &onSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Sidebar, &onBind, self, .{});
        _ = gtk.SignalListItemFactory.signals.unbind.connect(factory, *Sidebar, &onUnbind, self, .{});
        _ = gtk.SignalListItemFactory.signals.teardown.connect(factory, *Sidebar, &onTeardown, self, .{});

        const list_view = gtk.ListView.new(
            gobject.ext.as(gtk.SelectionModel, self.selection),
            gobject.ext.as(gtk.ListItemFactory, factory),
        );
        gtk.ListView.setShowSeparators(list_view, 1);
        gtk.ListView.setSingleClickActivate(list_view, 1);
        _ = gtk.ListView.signals.activate.connect(list_view, *Sidebar, &onActivate, self, .{});
        gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, list_view), "kelpie-sidebar-list");

        const scrolled = gtk.ScrolledWindow.new();
        gtk.ScrolledWindow.setPolicy(scrolled, .never, .automatic);
        gtk.ScrolledWindow.setChild(scrolled, gobject.ext.as(gtk.Widget, list_view));

        self.widget = gobject.ext.as(gtk.Widget, scrolled);

        self.refresh();
    }

    pub fn deinit(self: *Sidebar) void {
        freeRows(self.gpa, self.rows);
        self.rows = &.{};
    }

    pub fn setFocusCallback(self: *Sidebar, cb: FocusFn, data: ?*anyopaque) void {
        self.on_focus = cb;
        self.on_focus_data = data;
    }

    pub fn observer(self: *Sidebar) store_mod.ChangeObserver {
        return .{
            .ptr = self,
            .onChangedFn = &onStoreChanged,
            .onTransitionFn = &onStoreTransition,
        };
    }

    /// Repuebla `rows` y el `gio.ListStore` con un solo `splice` (criterio 1:
    /// una sola emisión de `items-changed`, sin parpadeo de selección).
    /// `buildRows` construye la lista nueva COMPLETA antes de tocar el
    /// ListStore o liberar `self.rows` — si falla por OOM, el sidebar se
    /// queda con el modelo anterior intacto (design §"Modelo de filas").
    pub fn refresh(self: *Sidebar) void {
        const new_rows = buildRows(self.gpa, self.store) catch |err| {
            std.log.err("sidebar: refresh failed: {t}", .{err});
            return;
        };

        // Remember the selected (device, pane) — restored by identity after
        // the splice, not by position (positions shift as rows reorder).
        var device_buf: [256]u8 = undefined;
        var pane_buf: [256]u8 = undefined;
        var restore: ?struct { device: []const u8, pane: []const u8 } = null;
        {
            const pos = gtk.SingleSelection.getSelected(self.selection);
            if (pos < self.rows.len and self.rows[pos].kind == .agent) {
                const old = self.rows[pos];
                if (old.device.len <= device_buf.len and old.pane.len <= pane_buf.len) {
                    @memcpy(device_buf[0..old.device.len], old.device);
                    @memcpy(pane_buf[0..old.pane.len], old.pane);
                    restore = .{ .device = device_buf[0..old.device.len], .pane = pane_buf[0..old.pane.len] };
                }
            }
        }

        const objects = self.gpa.alloc(*gobject.Object, new_rows.len) catch |err| {
            std.log.err("sidebar: refresh failed building row objects: {t}", .{err});
            freeRows(self.gpa, new_rows);
            return;
        };
        defer self.gpa.free(objects);
        for (objects, 0..) |*slot, i| {
            const obj = RowObject.new();
            obj.index = @intCast(i);
            slot.* = gobject.ext.as(gobject.Object, obj);
        }
        defer for (objects) |obj| gobject.Object.unref(obj);

        // `onBind` reads `self.rows` synchronously while `splice` runs (GTK binds
        // items as they're inserted, not on some later idle) — the swap has to
        // happen before the splice, or every row paints the stale model. Safe to
        // free the old rows here: `buildRows` above already succeeded, so this is
        // the only point after which nothing can fail.
        freeRows(self.gpa, self.rows);
        self.rows = new_rows;

        const old_n = gio.ListModel.getNItems(gobject.ext.as(gio.ListModel, self.list_store));
        gio.ListStore.splice(self.list_store, 0, old_n, objects.ptr, @intCast(objects.len));

        if (restore) |r| _ = self.selectByKey(r.device, r.pane);
    }

    /// Selects the row for `(device, pane)` if it exists. Returns whether it
    /// was found — used both to restore selection across a refresh and as
    /// the real seam behind `app_shell.focusAgent`.
    pub fn selectByKey(self: *Sidebar, device: []const u8, pane: []const u8) bool {
        for (self.rows, 0..) |row, i| {
            if (row.kind == .agent and std.mem.eql(u8, row.device, device) and std.mem.eql(u8, row.pane, pane)) {
                gtk.SingleSelection.setSelected(self.selection, @intCast(i));
                return true;
            }
        }
        return false;
    }
};

fn onStoreChanged(ptr: *anyopaque) void {
    const self: *Sidebar = @ptrCast(@alignCast(ptr));
    self.refresh();
}

fn onStoreTransition(ptr: *anyopaque, agent: *const Agent, from: types.AgentStatus, to: types.AgentStatus) void {
    // No-op: `applyEvent` always fires `onChanged` alongside a transition
    // (Store.zig's `fireTransition` + `fireChanged` pair), so `refresh()`
    // already runs via `onStoreChanged` for the same event.
    _ = ptr;
    _ = agent;
    _ = from;
    _ = to;
}

// ---------------------------------------------------------------------------
// Factory callbacks and row widget construction — GTK-backed, exercised by
// QA with a live window (`--demo-sidebar`), not by unit tests.
//
// PREGUNTA ABIERTA: la tabla de firmas de #16 no incluye un
// `gtk.ListItem.getChild` (o equivalente) para recuperar el widget que
// `setup()` habría creado, así que `bind()` no puede mutar un hijo
// persistente in-place como sugiere design §"Widgets" (`gtk.Box.remove` solo
// en el glifo). En vez de inventar esa firma, `bind()` construye el árbol de
// la fila completo y lo entrega con `setChild` (citada); `unbind()`/
// `teardown()` lo sueltan con `setChild(item, null)`. Efecto observable
// idéntico para el criterio 3 (el spinner no sobrevive fuera de `working`,
// porque ni siquiera el árbol que lo contiene sobrevive al unbind) y el
// reciclado de criterio 5 lo sigue dando el nodo "row" que gestiona GTK, no
// nuestro hijo — pero cada bind reconstruye labels/spinner en vez de
// reutilizarlos. Si `getChild` existe y se verifica, es la optimización
// natural.
// ---------------------------------------------------------------------------

fn onSetup(_: *gtk.SignalListItemFactory, p_object: *gobject.Object, _: *Sidebar) callconv(.c) void {
    const item = gobject.ext.cast(gtk.ListItem, p_object).?;
    gtk.ListItem.setActivatable(item, 1);
}

fn onBind(_: *gtk.SignalListItemFactory, p_object: *gobject.Object, sb: *Sidebar) callconv(.c) void {
    const item = gobject.ext.cast(gtk.ListItem, p_object).?;
    const obj = gtk.ListItem.getItem(item) orelse return;
    const row_obj = gobject.ext.cast(RowObject, obj) orelse return;
    if (row_obj.index >= sb.rows.len) return;
    gtk.ListItem.setChild(item, buildRowWidget(sb.rows[row_obj.index]));
}

fn onUnbind(_: *gtk.SignalListItemFactory, p_object: *gobject.Object, _: *Sidebar) callconv(.c) void {
    const item = gobject.ext.cast(gtk.ListItem, p_object).?;
    gtk.ListItem.setChild(item, null);
}

fn onTeardown(_: *gtk.SignalListItemFactory, p_object: *gobject.Object, _: *Sidebar) callconv(.c) void {
    const item = gobject.ext.cast(gtk.ListItem, p_object).?;
    gtk.ListItem.setChild(item, null);
}

fn onActivate(_: *gtk.ListView, p_position: c_uint, sb: *Sidebar) callconv(.c) void {
    if (p_position >= sb.rows.len) return;
    const row = sb.rows[p_position];
    if (row.kind != .agent) return;
    if (sb.on_focus) |cb| cb(sb.on_focus_data, row.device, row.pane);
}

fn rowCssClass(kind: RowKind) [:0]const u8 {
    return switch (kind) {
        .device => "kelpie-row-device",
        .workspace => "kelpie-row-workspace",
        .agent => "kelpie-row-agent",
    };
}

/// Builds one row's widget tree from scratch — see the "PREGUNTA ABIERTA"
/// note above on why this happens on every `bind()` instead of mutating a
/// persistent child.
fn buildRowWidget(row: Row) *gtk.Widget {
    const outer = gtk.Box.new(.horizontal, 6);
    const outer_w = gobject.ext.as(gtk.Widget, outer);
    gtk.Widget.addCssClass(outer_w, rowCssClass(row.kind));
    gtk.Widget.setValign(outer_w, .center);
    gtk.Widget.setMarginStart(outer_w, 8);
    gtk.Widget.setMarginEnd(outer_w, 8);

    const text_box = gtk.Box.new(.vertical, 0);
    const text_w = gobject.ext.as(gtk.Widget, text_box);
    gtk.Widget.setValign(text_w, .center);
    gtk.Widget.setHexpand(text_w, 1);

    const title = gtk.Label.new(row.title.ptr);
    gtk.Label.setXalign(title, 0);
    // PREGUNTA ABIERTA: sin verificar el nombre del miembro `end` de
    // pango.EllipsizeMode en la tabla de #16 (solo cita su ubicación), no se
    // llama a setEllipsize — títulos largos se recortan por overflow de CSS
    // en vez de con "…". Ningún criterio de aceptación lo exige.
    gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, title), "kelpie-row-title");
    gtk.Box.append(text_box, gobject.ext.as(gtk.Widget, title));

    if (row.subtitle) |s| {
        const subtitle = gtk.Label.new(s.ptr);
        gtk.Label.setXalign(subtitle, 0);
        gtk.Widget.addCssClass(gobject.ext.as(gtk.Widget, subtitle), "kelpie-row-subtitle");
        gtk.Box.append(text_box, gobject.ext.as(gtk.Widget, subtitle));
    }

    gtk.Box.append(outer, text_w);

    if (row.kind != .device) {
        if (glyphWidget(row.status)) |glyph| {
            gtk.Widget.setSizeRequest(glyph, 16, -1);
            gtk.Widget.setValign(glyph, .center);
            gtk.Box.append(outer, glyph);
        }
    }

    return outer_w;
}

/// `AgentStatusGlyph` (design §"Widgets"): creates exactly the widget the
/// status calls for, nothing hidden. `working` → spinning `gtk.Spinner`;
/// `blocked`/`done` → a `gtk.Label` glyph; `idle`/`unknown` → no widget.
fn glyphWidget(status: types.AgentStatus) ?*gtk.Widget {
    return switch (glyphKindForStatus(status)) {
        .none => null,
        .spinner => blk: {
            const sp = gtk.Spinner.new();
            const w = gobject.ext.as(gtk.Widget, sp);
            gtk.Widget.addCssClass(w, "kelpie-glyph-working");
            gtk.Spinner.setSpinning(sp, 1);
            break :blk w;
        },
        .blocked => blk: {
            const lbl = gtk.Label.new("\u{f0026}"); // 󰀦 — same glyph as design §"Widgets".
            const w = gobject.ext.as(gtk.Widget, lbl);
            gtk.Widget.addCssClass(w, "kelpie-glyph-blocked");
            break :blk w;
        },
        .done => blk: {
            const lbl = gtk.Label.new("\u{f012c}"); // 󰄬 — same glyph as design §"Widgets".
            const w = gobject.ext.as(gtk.Widget, lbl);
            gtk.Widget.addCssClass(w, "kelpie-glyph-done");
            break :blk w;
        },
    };
}

// ---------------------------------------------------------------------------
// Tests — the pure `buildRows`/`glyphKindForStatus`/`buildSubtitle` logic
// needs no live GtkWidget, no window. `std.testing.allocator` also proves
// `freeRows` doesn't leak (a missing free trips the GPA leak check).
// ---------------------------------------------------------------------------

const testing = std.testing;

// Escenario: cero color literal en el CSS de kelpie (ADR-0001 §5, criterio 4).
// Un grep manual que nadie corre no cuenta como cumplido — fija la regla en
// el árbol de tests.
test "kelpie_css carries no literal color — everything resolves via var(--…)" {
    const app_shell = @import("app_shell.zig");
    const css = app_shell.kelpie_css;
    for ([_][]const u8{ "#", "rgb(", "rgba(", "hsl(", "hsla(" }) |needle| {
        if (std.mem.indexOf(u8, css, needle)) |i| {
            std.debug.print("kelpie_css: found literal color token \"{s}\" at byte {d}\n", .{ needle, i });
            return error.LiteralColorInCss;
        }
    }
}

fn testSnapshotAgent(pane_id: []const u8, workspace_id: []const u8, status: types.AgentStatus, revision: u64) types.AgentInfo {
    return .{
        .terminal_id = pane_id,
        .agent_status = status,
        .workspace_id = workspace_id,
        .tab_id = "tab-1",
        .pane_id = pane_id,
        .focused = false,
        .revision = revision,
    };
}

// Escenario: cuatro agentes idle no dibujan nada.
test "buildRows: 4 idle agents in 2 workspaces produce 7 rows, none carrying a glyph" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{
        testSnapshotAgent("p1", "ws-a", .idle, 1),
        testSnapshotAgent("p2", "ws-a", .idle, 2),
        testSnapshotAgent("p3", "ws-b", .idle, 3),
        testSnapshotAgent("p4", "ws-b", .idle, 4),
    };
    try store.applySnapshot(.{
        .version = "1",
        .protocol = 1,
        .workspaces = &.{},
        .tabs = &.{},
        .panes = &.{},
        .layouts = &.{},
        .agents = &agents,
    });

    const rows = try buildRows(testing.allocator, &store);
    defer freeRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 7), rows.len);
    try testing.expectEqual(RowKind.device, rows[0].kind);
    for (rows) |row| {
        try testing.expectEqual(GlyphKind.none, glyphKindForStatus(row.status));
    }
}

// Escenario: un agente que se bloquea sube al primer lugar.
test "buildRows: an agent going blocked pulls its workspace to first place" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Revisions descending pick ws-a first with no blocking at all (urgency
    // tie -> revision desc), so the control assertion below is a real red
    // without the applyEvent — proving the reorder, not just restating the
    // pre-existing revision order.
    const agents = [_]types.AgentInfo{
        testSnapshotAgent("p1", "ws-a", .idle, 4),
        testSnapshotAgent("p2", "ws-a", .idle, 3),
        testSnapshotAgent("p3", "ws-b", .idle, 2),
        testSnapshotAgent("p4", "ws-b", .idle, 1),
    };
    try store.applySnapshot(.{
        .version = "1",
        .protocol = 1,
        .workspaces = &.{},
        .tabs = &.{},
        .panes = &.{},
        .layouts = &.{},
        .agents = &agents,
    });

    // Control: before blocking anything, ws-a (highest revision) is first.
    {
        const rows = try buildRows(testing.allocator, &store);
        defer freeRows(testing.allocator, rows);
        try testing.expectEqualStrings("ws-a", rows[1].title);
    }

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(testing.allocator);
    try obj.put(testing.allocator, "pane_id", .{ .string = "p4" });
    try obj.put(testing.allocator, "workspace_id", .{ .string = "ws-b" });
    try obj.put(testing.allocator, "agent_status", .{ .string = "blocked" });
    try store.applyEvent(.{ .event = .pane_agent_status_changed, .data = .{ .object = obj } });

    const rows = try buildRows(testing.allocator, &store);
    defer freeRows(testing.allocator, rows);

    // 1 device row + (workspace, agent, agent) for ws-b now first + same for ws-a.
    try testing.expectEqual(@as(usize, 7), rows.len);
    try testing.expectEqual(RowKind.workspace, rows[1].kind);
    try testing.expectEqualStrings("ws-b", rows[1].title);
    try testing.expectEqual(types.AgentStatus.blocked, rows[1].status);
    try testing.expectEqual(RowKind.agent, rows[2].kind);
    try testing.expectEqualStrings("p4", rows[2].pane);
    try testing.expectEqual(types.AgentStatus.blocked, rows[2].status);
}

test "glyphKindForStatus: working spins, blocked/done glyph, idle/unknown draw nothing" {
    try testing.expectEqual(GlyphKind.spinner, glyphKindForStatus(.working));
    try testing.expectEqual(GlyphKind.blocked, glyphKindForStatus(.blocked));
    try testing.expectEqual(GlyphKind.done, glyphKindForStatus(.done));
    try testing.expectEqual(GlyphKind.none, glyphKindForStatus(.idle));
    try testing.expectEqual(GlyphKind.none, glyphKindForStatus(.unknown));
}

test "buildRows: agent row subtitle joins agent and cwd, falls back to whichever half exists" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{
        .{
            .terminal_id = "p1",
            .agent_status = .idle,
            .workspace_id = "ws-a",
            .tab_id = "tab-1",
            .pane_id = "p1",
            .focused = false,
            .revision = 1,
            .agent = "claude",
            .cwd = "~/kelpie",
        },
        .{
            .terminal_id = "p2",
            .agent_status = .idle,
            .workspace_id = "ws-a",
            .tab_id = "tab-1",
            .pane_id = "p2",
            .focused = false,
            .revision = 2,
            .agent = "claude",
        },
        .{
            .terminal_id = "p3",
            .agent_status = .idle,
            .workspace_id = "ws-a",
            .tab_id = "tab-1",
            .pane_id = "p3",
            .focused = false,
            .revision = 3,
        },
    };
    try store.applySnapshot(.{
        .version = "1",
        .protocol = 1,
        .workspaces = &.{},
        .tabs = &.{},
        .panes = &.{},
        .layouts = &.{},
        .agents = &agents,
    });

    const rows = try buildRows(testing.allocator, &store);
    defer freeRows(testing.allocator, rows);

    // rows: [device, workspace, p1, p2, p3] — orderedAgents keeps insertion
    // order for equal urgency/revision ties broken by descending revision,
    // so p3 (revision 3) sorts before p2 (2) before p1 (1).
    var by_pane = std.StringHashMap(Row).init(testing.allocator);
    defer by_pane.deinit();
    for (rows) |row| {
        if (row.kind == .agent) try by_pane.put(row.pane, row);
    }

    try testing.expectEqualStrings("claude · ~/kelpie", by_pane.get("p1").?.subtitle.?);
    try testing.expectEqualStrings("claude", by_pane.get("p2").?.subtitle.?);
    try testing.expect(by_pane.get("p3").?.subtitle == null);
}

test "buildRows: empty store produces zero rows" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const rows = try buildRows(testing.allocator, &store);
    defer freeRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 0), rows.len);
}

// Every other test above leaves `snapshot.workspaces` empty, so the
// `store.workspaces.getPtr(...)` branch in buildRows (design §Agrupado:
// "el nombre visible del espacio sale de store.workspaces... si no está en
// el mapa, se cae al workspace_id") never actually runs its "found" half —
// the fallback is all any prior test could prove. This one seeds a
// `WorkspaceInfo` with a label that differs from its `workspace_id` and
// pins that the *label*, not the id, ends up as the row title.
test "buildRows: workspace title comes from store.workspaces label when known" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{
        testSnapshotAgent("p1", "ws-a", .idle, 1),
    };
    const workspaces = [_]types.WorkspaceInfo{.{
        .workspace_id = "ws-a",
        .number = 1,
        .label = "Proyecto Kelpie",
        .focused = true,
        .pane_count = 1,
        .tab_count = 1,
        .active_tab_id = "tab-1",
        .agent_status = .idle,
    }};
    try store.applySnapshot(.{
        .version = "1",
        .protocol = 1,
        .workspaces = &workspaces,
        .tabs = &.{},
        .panes = &.{},
        .layouts = &.{},
        .agents = &agents,
    });

    const rows = try buildRows(testing.allocator, &store);
    defer freeRows(testing.allocator, rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(RowKind.workspace, rows[1].kind);
    try testing.expectEqualStrings("Proyecto Kelpie", rows[1].title);
}
