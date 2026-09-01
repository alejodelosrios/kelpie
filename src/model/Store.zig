const std = @import("std");
const json = std.json;
const testing = std.testing;

const types = @import("../herdr/types.zig");

// ---------------------------------------------------------------------------
// Store — in-memory source of truth for the sidebar agent list.
//
// Concurrency contract: `applySnapshot`/`applyEvent` are called only from
// the dispatcher context (same thread, in practice the UI thread) — the same
// contract `Events.zig`'s `Dispatcher` already imposes on its callbacks.
// No internal mutex; the caller guarantees single-threaded access, matching
// how `Events.zig`'s `Dispatcher` marshals `on_event`/`on_resynced` off the
// reader thread (Events.zig:9-13).
// ---------------------------------------------------------------------------

pub const Agent = struct {
    device_id: []const u8,
    pane_id: []const u8,
    workspace_id: []const u8,
    tab_id: []const u8,
    status: types.AgentStatus,
    revision: u64,
    focused: bool,
    agent: ?[]const u8 = null,
    display_agent: ?[]const u8 = null,
    title: ?[]const u8 = null,
    terminal_title_stripped: ?[]const u8 = null,
    cwd: ?[]const u8 = null,

    /// title ?? terminal_title_stripped ?? agent ?? pane_id — regla del issue.
    pub fn displayTitle(self: Agent) []const u8 {
        return self.title orelse self.terminal_title_stripped orelse self.agent orelse self.pane_id;
    }
};

// ---------------------------------------------------------------------------
// HashMap key types with custom hash/eql contexts (AutoContext rejects
// structs containing slices because the intent is ambiguous — pointer vs
// contents). These hash the slice contents.
// ---------------------------------------------------------------------------

const AgentKey = struct {
    device_id: []const u8,
    pane_id: []const u8,
};

const AgentKeyContext = struct {
    pub fn hash(_: AgentKeyContext, key: AgentKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.device_id);
        h.update(key.pane_id);
        return h.final();
    }

    pub fn eql(_: AgentKeyContext, a: AgentKey, b: AgentKey) bool {
        return std.mem.eql(u8, a.device_id, b.device_id) and
            std.mem.eql(u8, a.pane_id, b.pane_id);
    }
};

const AgentMap = std.hash_map.HashMap(
    AgentKey,
    Agent,
    AgentKeyContext,
    std.hash_map.default_max_load_percentage,
);

const WorkspaceKey = struct {
    device_id: []const u8,
    workspace_id: []const u8,
};

const WorkspaceKeyContext = struct {
    pub fn hash(_: WorkspaceKeyContext, key: WorkspaceKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.device_id);
        h.update(key.workspace_id);
        return h.final();
    }

    pub fn eql(_: WorkspaceKeyContext, a: WorkspaceKey, b: WorkspaceKey) bool {
        return std.mem.eql(u8, a.device_id, b.device_id) and
            std.mem.eql(u8, a.workspace_id, b.workspace_id);
    }
};

const WorkspaceMap = std.hash_map.HashMap(
    WorkspaceKey,
    types.WorkspaceInfo,
    WorkspaceKeyContext,
    std.hash_map.default_max_load_percentage,
);

const TabKey = struct {
    device_id: []const u8,
    tab_id: []const u8,
};

const TabKeyContext = struct {
    pub fn hash(_: TabKeyContext, key: TabKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.device_id);
        h.update(key.tab_id);
        return h.final();
    }

    pub fn eql(_: TabKeyContext, a: TabKey, b: TabKey) bool {
        return std.mem.eql(u8, a.device_id, b.device_id) and
            std.mem.eql(u8, a.tab_id, b.tab_id);
    }
};

const TabMap = std.hash_map.HashMap(
    TabKey,
    types.TabInfo,
    TabKeyContext,
    std.hash_map.default_max_load_percentage,
);

pub const ChangeObserver = struct {
    ptr: *anyopaque,
    onChangedFn: *const fn (ptr: *anyopaque) void,
    onTransitionFn: *const fn (ptr: *anyopaque, agent: *const Agent, from: types.AgentStatus, to: types.AgentStatus) void,

    pub fn onChanged(self: ChangeObserver) void {
        self.onChangedFn(self.ptr);
    }

    pub fn onTransition(self: ChangeObserver, agent: *const Agent, from: types.AgentStatus, to: types.AgentStatus) void {
        self.onTransitionFn(self.ptr, agent, from, to);
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    agents: AgentMap,
    workspaces: WorkspaceMap,
    tabs: TabMap,
    observers: std.array_list.Managed(ChangeObserver),
    /// Fingerprint of the last applied snapshot's sidebar-relevant fields.
    /// Used by `applySnapshot` to skip mutation and `fireChanged` when the
    /// snapshot hasn't changed anything the sidebar paints. `null` means
    /// "no snapshot applied yet" — the first snapshot always applies.
    last_fingerprint: ?u64 = null,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{
            .gpa = gpa,
            .agents = AgentMap.initContext(gpa, .{}),
            .workspaces = WorkspaceMap.initContext(gpa, .{}),
            .tabs = TabMap.initContext(gpa, .{}),
            .observers = std.array_list.Managed(ChangeObserver).init(gpa),
        };
    }

    pub fn deinit(self: *Store) void {
        freeAgentEntries(self.gpa, &self.agents);
        self.agents.deinit();
        freeWorkspaceEntries(self.gpa, &self.workspaces);
        self.workspaces.deinit();
        freeTabEntries(self.gpa, &self.tabs);
        self.tabs.deinit();
        self.observers.deinit();
    }

    pub fn addObserver(self: *Store, observer: ChangeObserver) !void {
        try self.observers.append(observer);
    }

    // -----------------------------------------------------------------------
    // applySnapshot — full replacement from session.snapshot
    // -----------------------------------------------------------------------

    pub fn applySnapshot(self: *Store, snapshot: types.SessionSnapshot) !void {
        // #84: Fingerprint-based no-op guard. If the snapshot hasn't changed
        // anything the sidebar paints, skip mutation and fireChanged entirely.
        // This prevents the churn of ~1 reconstruction/second when herdr
        // emits events (pane.updated ~1/s in idle) that don't change the
        // sidebar's view.
        //
        // The fingerprint is computed BEFORE mutation. We null out
        // `last_fingerprint` immediately so that if mutation fails midway
        // (e.g. OOM on gpa.dupe), the next snapshot — identical or not —
        // won't be incorrectly discarded by the guard. The final assignment
        // `self.last_fingerprint = fp` only runs if the whole mutation
        // succeeds.
        //
        // Risk: if `buildRows` (src/ui/sidebar.zig) starts painting a new
        // field and nobody adds it to `computeFingerprint`, the sidebar goes
        // stale silently. Test scenarios 7/8 pin both directions.
        const fp = computeFingerprint(snapshot);
        if (self.last_fingerprint) |last| {
            if (fp == last) return; // No-op: nothing sidebar-relevant changed
        }

        // Null out before any destructive mutation so a midway failure
        // doesn't leave a stale fingerprint that blocks the next snapshot.
        self.last_fingerprint = null;

        // Agents
        freeAgentEntries(self.gpa, &self.agents);
        self.agents.clearAndFree();
        for (snapshot.agents) |info| {
            const key = AgentKey{
                .device_id = try self.gpa.dupe(u8, "local"),
                .pane_id = try self.gpa.dupe(u8, info.pane_id),
            };
            errdefer {
                self.gpa.free(key.device_id);
                self.gpa.free(key.pane_id);
            }
            const agent = Agent{
                .device_id = key.device_id,
                .pane_id = key.pane_id,
                .workspace_id = try self.gpa.dupe(u8, info.workspace_id),
                .tab_id = try self.gpa.dupe(u8, info.tab_id),
                .status = info.agent_status,
                .revision = info.revision,
                .focused = info.focused,
                .agent = try dupeOptional(self.gpa, info.agent),
                .display_agent = try dupeOptional(self.gpa, info.display_agent),
                .title = try dupeOptional(self.gpa, info.title),
                .terminal_title_stripped = try dupeOptional(self.gpa, info.terminal_title_stripped),
                .cwd = try dupeOptional(self.gpa, info.cwd),
            };
            try self.agents.put(key, agent);
        }

        // Workspaces
        freeWorkspaceEntries(self.gpa, &self.workspaces);
        self.workspaces.clearAndFree();
        for (snapshot.workspaces) |ws| {
            const key = WorkspaceKey{
                .device_id = try self.gpa.dupe(u8, "local"),
                .workspace_id = try self.gpa.dupe(u8, ws.workspace_id),
            };
            errdefer {
                self.gpa.free(key.device_id);
                self.gpa.free(key.workspace_id);
            }
            try self.workspaces.put(key, try dupeWorkspaceInfo(self.gpa, ws));
        }

        // Tabs
        freeTabEntries(self.gpa, &self.tabs);
        self.tabs.clearAndFree();
        for (snapshot.tabs) |tab| {
            const key = TabKey{
                .device_id = try self.gpa.dupe(u8, "local"),
                .tab_id = try self.gpa.dupe(u8, tab.tab_id),
            };
            errdefer {
                self.gpa.free(key.device_id);
                self.gpa.free(key.tab_id);
            }
            try self.tabs.put(key, try dupeTabInfo(self.gpa, tab));
        }

        // Mutation succeeded: commit the fingerprint. If we get here via
        // an error, last_fingerprint is already null (set above), so the
        // next snapshot will be applied instead of incorrectly discarded.
        self.last_fingerprint = fp;

        fireChanged(&self.observers);
    }

    // -----------------------------------------------------------------------
    // applyEvent — incremental mutation from EventEnvelope
    // -----------------------------------------------------------------------

    pub fn applyEvent(self: *Store, envelope: types.EventEnvelope) !void {
        switch (envelope.event) {
            .pane_created, .pane_updated => {
                const parsed = try json.parseFromValue(
                    PanePayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const pane = parsed.value.pane;
                try upsertAgent(self, pane);
            },

            .pane_closed => {
                const parsed = try json.parseFromValue(
                    PaneClosedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const key = AgentKey{
                    .device_id = "local",
                    .pane_id = parsed.value.pane_id,
                };
                if (self.agents.fetchRemove(key)) |kv| {
                    freeAgentKey(self.gpa, kv.key);
                    freeAgentValue(self.gpa, kv.value);
                    fireChanged(&self.observers);
                }
            },

            .pane_agent_status_changed => {
                const parsed = try json.parseFromValue(
                    PaneAgentStatusChangedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const data = parsed.value;
                const key = AgentKey{
                    .device_id = "local",
                    .pane_id = data.pane_id,
                };
                if (self.agents.getPtr(key)) |existing| {
                    const from_status = existing.status;
                    existing.status = data.agent_status;
                    try updateOptionalField(self.gpa, &existing.agent, data.agent);
                    try updateOptionalField(self.gpa, &existing.display_agent, data.display_agent);
                    try updateOptionalField(self.gpa, &existing.title, data.title);
                    if (from_status != data.agent_status) {
                        fireTransition(&self.observers, existing, from_status, data.agent_status);
                    }
                    fireChanged(&self.observers);
                }
            },

            .pane_focused => {
                const parsed = try json.parseFromValue(
                    PaneFocusedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const data = parsed.value;
                // First pass: check if the pane exists at all (no mutation).
                var found = false;
                {
                    var check_it = self.agents.iterator();
                    while (check_it.next()) |entry| {
                        if (std.mem.eql(u8, entry.key_ptr.device_id, "local") and
                            std.mem.eql(u8, entry.key_ptr.pane_id, data.pane_id))
                        {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) return;
                // Second pass: apply focus.
                var it = self.agents.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.device_id, "local") and
                        std.mem.eql(u8, entry.key_ptr.pane_id, data.pane_id))
                    {
                        entry.value_ptr.focused = true;
                    } else if (std.mem.eql(u8, entry.key_ptr.device_id, "local")) {
                        entry.value_ptr.focused = false;
                    }
                }
                fireChanged(&self.observers);
            },

            .workspace_created, .workspace_updated, .workspace_metadata_updated => {
                const parsed = try json.parseFromValue(
                    WorkspacePayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const ws = try dupeWorkspaceInfo(self.gpa, parsed.value.workspace);
                errdefer freeWorkspaceInfoStrings(self.gpa, ws);
                const key = WorkspaceKey{
                    .device_id = try self.gpa.dupe(u8, "local"),
                    .workspace_id = try self.gpa.dupe(u8, ws.workspace_id),
                };
                errdefer {
                    self.gpa.free(key.device_id);
                    self.gpa.free(key.workspace_id);
                }
                if (try self.workspaces.fetchPut(key, ws)) |old| {
                    // fetchPut kept old.key in the map; free the duplicate
                    // key we just built (it was discarded by the map).
                    self.gpa.free(key.device_id);
                    self.gpa.free(key.workspace_id);
                    freeWorkspaceInfoStrings(self.gpa, old.value);
                }
                fireChanged(&self.observers);
            },

            .workspace_closed => {
                const parsed = try json.parseFromValue(
                    WorkspaceClosedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                // Remove by workspace_id — iterate because key also has device_id.
                var to_remove: ?WorkspaceKey = null;
                var it = self.workspaces.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.workspace_id, parsed.value.workspace_id)) {
                        to_remove = entry.key_ptr.*;
                        break;
                    }
                }
                if (to_remove) |key| {
                    if (self.workspaces.fetchRemove(key)) |kv| {
                        self.gpa.free(kv.key.device_id);
                        self.gpa.free(kv.key.workspace_id);
                        freeWorkspaceInfoStrings(self.gpa, kv.value);
                        fireChanged(&self.observers);
                    }
                }
            },

            .workspace_renamed => {
                const parsed = try json.parseFromValue(
                    WorkspaceRenamedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                var it = self.workspaces.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.workspace_id, parsed.value.workspace_id)) {
                        const duped_label = try self.gpa.dupe(u8, parsed.value.label);
                        self.gpa.free(entry.value_ptr.label);
                        entry.value_ptr.label = duped_label;
                        break;
                    }
                }
            },

            .workspace_focused => {
                const parsed = try json.parseFromValue(
                    WorkspaceFocusedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                var it = self.workspaces.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.workspace_id, parsed.value.workspace_id)) {
                        entry.value_ptr.focused = true;
                    } else if (std.mem.eql(u8, entry.key_ptr.device_id, "local")) {
                        entry.value_ptr.focused = false;
                    }
                }
                fireChanged(&self.observers);
            },

            .tab_created => {
                const parsed = try json.parseFromValue(
                    TabPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const tab = try dupeTabInfo(self.gpa, parsed.value.tab);
                errdefer freeTabInfoStrings(self.gpa, tab);
                const key = TabKey{
                    .device_id = try self.gpa.dupe(u8, "local"),
                    .tab_id = try self.gpa.dupe(u8, tab.tab_id),
                };
                errdefer {
                    self.gpa.free(key.device_id);
                    self.gpa.free(key.tab_id);
                }
                if (try self.tabs.fetchPut(key, tab)) |old| {
                    // fetchPut kept old.key in the map; free the duplicate
                    // key we just built (it was discarded by the map).
                    self.gpa.free(key.device_id);
                    self.gpa.free(key.tab_id);
                    freeTabInfoStrings(self.gpa, old.value);
                }
                fireChanged(&self.observers);
            },

            .tab_closed => {
                const parsed = try json.parseFromValue(
                    TabClosedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const key = TabKey{
                    .device_id = "local",
                    .tab_id = parsed.value.tab_id,
                };
                if (self.tabs.fetchRemove(key)) |kv| {
                    self.gpa.free(kv.key.device_id);
                    self.gpa.free(kv.key.tab_id);
                    freeTabInfoStrings(self.gpa, kv.value);
                    fireChanged(&self.observers);
                }
            },

            .tab_renamed => {
                const parsed = try json.parseFromValue(
                    TabRenamedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                var it = self.tabs.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.tab_id, parsed.value.tab_id)) {
                        const duped_label = try self.gpa.dupe(u8, parsed.value.label);
                        self.gpa.free(entry.value_ptr.label);
                        entry.value_ptr.label = duped_label;
                        break;
                    }
                }
            },

            .tab_focused => {
                const parsed = try json.parseFromValue(
                    TabFocusedPayload,
                    self.gpa,
                    envelope.data,
                    .{ .ignore_unknown_fields = true },
                );
                defer parsed.deinit();
                const data = parsed.value;
                // First pass: check if the tab exists (no mutation).
                var found = false;
                {
                    var check_it = self.tabs.iterator();
                    while (check_it.next()) |entry| {
                        if (std.mem.eql(u8, entry.key_ptr.tab_id, data.tab_id)) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) return;
                // Second pass: apply focus.
                var it = self.tabs.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.tab_id, data.tab_id)) {
                        entry.value_ptr.focused = true;
                    } else if (std.mem.eql(u8, entry.value_ptr.workspace_id, data.workspace_id)) {
                        entry.value_ptr.focused = false;
                    }
                }
                fireChanged(&self.observers);
            },

            // Explicit no-op for event kinds outside this issue's scope.
            // Never `unreachable` — events may arrive in any order.
            else => {},
        }
    }

    // -----------------------------------------------------------------------
    // orderedAgents — sorted by urgency (blocked > done > working > idle > unknown),
    // then by revision descending.
    // -----------------------------------------------------------------------

    pub fn orderedAgents(self: *Store, allocator: std.mem.Allocator) !std.array_list.Managed(*const Agent) {
        var list = std.array_list.Managed(*const Agent).init(allocator);
        var it = self.agents.iterator();
        while (it.next()) |entry| {
            try list.append(entry.value_ptr);
        }
        std.sort.block(*const Agent, list.items, {}, lessThan);
        return list;
    }

    /// Computes a fingerprint of the snapshot's sidebar-relevant fields.
    /// The fingerprint is order-independent (uses wrapping addition to combine
    /// per-row hashes) so that iteration order differences don't cause false
    /// mismatches.
    ///
    /// Fields included: everything the sidebar paints (see `buildRows` in
    /// `src/ui/sidebar.zig`). Excluded on purpose: `revision` (changes with
    /// every byte of terminal output — exactly the noise we're filtering) and
    /// `terminal_title` (changes with the prompt; `terminal_title_stripped`
    /// is included because the sidebar paints it in the subtitle).
    ///
    /// Risk declared: if `buildRows` starts painting a new field and nobody
    /// adds it here, the sidebar goes stale silently. The test scenarios
    /// "applySnapshot: un snapshot con la misma huella no dispara onChanged"
    /// and "applySnapshot: un cambio de agent_status SÍ dispara onChanged"
    /// pin both directions.
    pub fn computeFingerprint(snapshot: types.SessionSnapshot) u64 {
        var combined: u64 = 0;

        // Agents
        for (snapshot.agents) |info| {
            var h = std.hash.Wyhash.init(0);
            h.update(info.pane_id);
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&info.agent_status));
            h.update(&[_]u8{0});
            h.update(info.workspace_id);
            h.update(&[_]u8{0});
            h.update(info.tab_id);
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&info.focused));
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&info.state_change_seq));
            h.update(&[_]u8{0});
            h.update(info.agent orelse "");
            h.update(&[_]u8{0});
            h.update(info.display_agent orelse "");
            h.update(&[_]u8{0});
            h.update(info.title orelse "");
            h.update(&[_]u8{0});
            h.update(info.terminal_title_stripped orelse "");
            h.update(&[_]u8{0});
            h.update(info.cwd orelse "");
            h.update(&[_]u8{0});
            combined +%= h.final();
        }

        // Workspaces
        for (snapshot.workspaces) |ws| {
            var h = std.hash.Wyhash.init(0);
            h.update(ws.workspace_id);
            h.update(&[_]u8{0});
            h.update(ws.label);
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&ws.number));
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&ws.focused));
            h.update(&[_]u8{0});
            h.update(std.mem.asBytes(&ws.agent_status));
            h.update(&[_]u8{0});
            combined +%= h.final();
        }

        // Number of rows (agents + workspaces) as a tiebreaker
        combined +%= snapshot.agents.len;
        combined +%= snapshot.workspaces.len;

        return combined;
    }
};

// ---------------------------------------------------------------------------
// Event payload structs — minimal, only the fields the Store needs.
// `ignore_unknown_fields = true` handles extra fields (e.g. `type`, `state_labels`).
// ---------------------------------------------------------------------------

const PanePayload = struct {
    pane: types.PaneInfo,
};

const PaneClosedPayload = struct {
    pane_id: []const u8,
    workspace_id: []const u8,
};

const PaneAgentStatusChangedPayload = struct {
    pane_id: []const u8,
    workspace_id: []const u8,
    agent_status: types.AgentStatus,
    agent: ?[]const u8 = null,
    display_agent: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

const PaneFocusedPayload = struct {
    pane_id: []const u8,
    workspace_id: []const u8,
};

const WorkspacePayload = struct {
    workspace: types.WorkspaceInfo,
};

const WorkspaceClosedPayload = struct {
    workspace_id: []const u8,
};

const WorkspaceRenamedPayload = struct {
    workspace_id: []const u8,
    label: []const u8,
};

const WorkspaceFocusedPayload = struct {
    workspace_id: []const u8,
};

const TabPayload = struct {
    tab: types.TabInfo,
};

const TabClosedPayload = struct {
    tab_id: []const u8,
    workspace_id: []const u8,
};

const TabRenamedPayload = struct {
    tab_id: []const u8,
    workspace_id: []const u8,
    label: []const u8,
};

const TabFocusedPayload = struct {
    tab_id: []const u8,
    workspace_id: []const u8,
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn upsertAgent(self: *Store, pane: types.PaneInfo) !void {
    const key = AgentKey{
        .device_id = "local",
        .pane_id = pane.pane_id,
    };
    if (self.agents.getPtr(key)) |existing| {
        // #84: upsertAgent deja de ser fuente de `agent_status`. La verdad
        // viene de `session.snapshot` (vía `applySnapshot`), no de los
        // eventos de pane. Los eventos de pane son solo SEÑAL de que algo
        // cambió — el resync con debounce pide el snapshot y `applySnapshot`
        // aplica el estado real.
        //
        // Medido contra la sesión real (herdr 0.8.2, 14 panes / 7 agentes):
        // ~1 evento/s en reposo, y 30 de 30 eventos en vivo NO cambiaron
        // nada que el sidebar pinte. Cada `fireChanged` dispara
        // `Sidebar.refresh()` → `gio.ListStore.splice(0, old_n, ...)`
        // (src/ui/sidebar.zig:364), que reconstruye TODAS las filas.
        // Sin esta guarda, el issue entrega una reconstrucción completa del
        // sidebar una vez por segundo, para siempre.
        //
        // Solo disparamos `fireChanged` si cambió algo estructural que el
        // sidebar pinta: workspace_id, tab_id o focused. `revision` es ruido
        // puro de salida del terminal y no merece un repintado.
        var changed = false;

        // Compare workspace_id before overwriting
        if (!std.mem.eql(u8, existing.workspace_id, pane.workspace_id)) {
            const duped_ws = try self.gpa.dupe(u8, pane.workspace_id);
            self.gpa.free(existing.workspace_id);
            existing.workspace_id = duped_ws;
            changed = true;
        }

        // Compare tab_id before overwriting
        if (!std.mem.eql(u8, existing.tab_id, pane.tab_id)) {
            const duped_tab = try self.gpa.dupe(u8, pane.tab_id);
            self.gpa.free(existing.tab_id);
            existing.tab_id = duped_tab;
            changed = true;
        }

        // Compare focused before overwriting
        if (existing.focused != pane.focused) {
            existing.focused = pane.focused;
            changed = true;
        }

        // Always update revision (it's cheap and useful for ordering)
        existing.revision = pane.revision;

        if (changed) {
            fireChanged(&self.observers);
        }
    }
    // Antes había aquí una rama que CREABA el agente desde un evento de pane.
    // Se quitó: el payload de `pane.created`/`pane.updated` no trae `agent`,
    // ni `title`, ni `cwd` —comprobado contra la sesión real—, así que lo que
    // creaba eran filas con el `pane_id` pelado y sin subtítulo. Y `resync`
    // ahora falla el ciclo si no consigue snapshot, así que la identidad de un
    // agente viene SIEMPRE de `applySnapshot`, que es lo único que la tiene.
    //
    // Consecuencia declarada: un agente que nace estando kelpie conectado no
    // aparece hasta el siguiente resync. `pane.agent_detected` sería la señal
    // para pedirlo, pero su payload solo trae `pane_id`/`workspace_id`, así que
    // exige una costura que pida un resync bajo demanda — va a CONCERNS.md.
}

fn urgencyRank(status: types.AgentStatus) u8 {
    return switch (status) {
        .blocked => 0,
        .done => 1,
        .working => 2,
        .idle => 3,
        .unknown => 4,
    };
}

fn lessThan(_: void, a: *const Agent, b: *const Agent) bool {
    const rank_a = urgencyRank(a.status);
    const rank_b = urgencyRank(b.status);
    if (rank_a != rank_b) return rank_a < rank_b;
    return a.revision > b.revision;
}

fn fireChanged(observers: *const std.array_list.Managed(ChangeObserver)) void {
    for (observers.items) |obs| {
        obs.onChanged();
    }
}

fn fireTransition(
    observers: *const std.array_list.Managed(ChangeObserver),
    agent: *const Agent,
    from: types.AgentStatus,
    to: types.AgentStatus,
) void {
    for (observers.items) |obs| {
        obs.onTransition(agent, from, to);
    }
}

fn dupeOptional(gpa: std.mem.Allocator, val: ?[]const u8) !?[]const u8 {
    if (val) |v| return try gpa.dupe(u8, v);
    return null;
}

fn freeOptional(gpa: std.mem.Allocator, val: ?[]const u8) void {
    if (val) |v| gpa.free(v);
}

fn updateOptionalField(gpa: std.mem.Allocator, field: *?[]const u8, new_val: ?[]const u8) !void {
    // `null` means "the event does not carry this field", not "set it to
    // null".  Real deletion arrives via `applySnapshot`, which replaces the
    // whole agent.  Skipping avoids a `pane_agent_status_changed` that only
    // carries `agent_status` from wiping `agent`/`display_agent`/`title`.
    const val = new_val orelse return;
    const duped = try gpa.dupe(u8, val);
    freeOptional(gpa, field.*);
    field.* = duped;
}

fn freeAgentKey(gpa: std.mem.Allocator, key: AgentKey) void {
    gpa.free(key.device_id);
    gpa.free(key.pane_id);
}

fn freeAgentValue(gpa: std.mem.Allocator, agent: Agent) void {
    // device_id and pane_id are aliased from the key — freed via freeAgentKey.
    gpa.free(agent.workspace_id);
    gpa.free(agent.tab_id);
    freeOptional(gpa, agent.agent);
    freeOptional(gpa, agent.display_agent);
    freeOptional(gpa, agent.title);
    freeOptional(gpa, agent.terminal_title_stripped);
    freeOptional(gpa, agent.cwd);
}

fn freeAgentEntries(gpa: std.mem.Allocator, map: *AgentMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        freeAgentKey(gpa, entry.key_ptr.*);
        freeAgentValue(gpa, entry.value_ptr.*);
    }
}

fn freeWorkspaceEntries(gpa: std.mem.Allocator, map: *WorkspaceMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.device_id);
        gpa.free(entry.key_ptr.workspace_id);
        freeWorkspaceInfoStrings(gpa, entry.value_ptr.*);
    }
}

fn freeTabEntries(gpa: std.mem.Allocator, map: *TabMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.device_id);
        gpa.free(entry.key_ptr.tab_id);
        freeTabInfoStrings(gpa, entry.value_ptr.*);
    }
}

fn dupeWorkspaceInfo(gpa: std.mem.Allocator, ws: types.WorkspaceInfo) !types.WorkspaceInfo {
    return .{
        .workspace_id = try gpa.dupe(u8, ws.workspace_id),
        .number = ws.number,
        .label = try gpa.dupe(u8, ws.label),
        .focused = ws.focused,
        .pane_count = ws.pane_count,
        .tab_count = ws.tab_count,
        .active_tab_id = try gpa.dupe(u8, ws.active_tab_id),
        .agent_status = ws.agent_status,
    };
}

fn freeWorkspaceInfoStrings(gpa: std.mem.Allocator, ws: types.WorkspaceInfo) void {
    gpa.free(ws.workspace_id);
    gpa.free(ws.label);
    gpa.free(ws.active_tab_id);
}

fn dupeTabInfo(gpa: std.mem.Allocator, tab: types.TabInfo) !types.TabInfo {
    return .{
        .tab_id = try gpa.dupe(u8, tab.tab_id),
        .workspace_id = try gpa.dupe(u8, tab.workspace_id),
        .number = tab.number,
        .label = try gpa.dupe(u8, tab.label),
        .focused = tab.focused,
        .pane_count = tab.pane_count,
        .agent_status = tab.agent_status,
    };
}

fn freeTabInfoStrings(gpa: std.mem.Allocator, tab: types.TabInfo) void {
    gpa.free(tab.tab_id);
    gpa.free(tab.workspace_id);
    gpa.free(tab.label);
}

// ---------------------------------------------------------------------------
// Tests — Gherkin scenarios from the design
// ---------------------------------------------------------------------------

fn makeSnapshot(agents: []const types.AgentInfo, workspaces: []const types.WorkspaceInfo, tabs: []const types.TabInfo) types.SessionSnapshot {
    return .{
        .version = "1",
        .protocol = 20,
        .workspaces = workspaces,
        .tabs = tabs,
        .panes = &.{},
        .layouts = &.{},
        .agents = agents,
    };
}

fn makeAgentInfo(pane_id: []const u8, status: types.AgentStatus, revision: u64) types.AgentInfo {
    return .{
        .terminal_id = "t1",
        .agent_status = status,
        .workspace_id = "w1",
        .tab_id = "tab1",
        .pane_id = pane_id,
        .focused = false,
        .revision = revision,
    };
}

const TestObserver = struct {
    changed_count: u32 = 0,
    transition_count: u32 = 0,
    last_transition_from: ?types.AgentStatus = null,
    last_transition_to: ?types.AgentStatus = null,
    last_transition_agent: ?*const Agent = null,

    fn observer(self: *TestObserver) ChangeObserver {
        return .{
            .ptr = self,
            .onChangedFn = onChangedImpl,
            .onTransitionFn = onTransitionImpl,
        };
    }

    fn onChangedImpl(ptr: *anyopaque) void {
        const self: *TestObserver = @ptrCast(@alignCast(ptr));
        self.changed_count += 1;
    }

    fn onTransitionImpl(ptr: *anyopaque, agent: *const Agent, from: types.AgentStatus, to: types.AgentStatus) void {
        const self: *TestObserver = @ptrCast(@alignCast(ptr));
        self.transition_count += 1;
        self.last_transition_from = from;
        self.last_transition_to = to;
        self.last_transition_agent = agent;
    }
};

test "applySnapshot populates agents; orderedAgents sorts by urgency then revision" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{
        makeAgentInfo("p1", .idle, 1),
        makeAgentInfo("p2", .working, 2),
        makeAgentInfo("p3", .blocked, 3),
        makeAgentInfo("p4", .done, 4),
    };
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();

    try testing.expectEqual(@as(usize, 4), ordered.items.len);
    // blocked (rank 0) first
    try testing.expectEqual(types.AgentStatus.blocked, ordered.items[0].status);
    // done (rank 1) second
    try testing.expectEqual(types.AgentStatus.done, ordered.items[1].status);
    // working (rank 2) third
    try testing.expectEqual(types.AgentStatus.working, ordered.items[2].status);
    // idle (rank 3) last
    try testing.expectEqual(types.AgentStatus.idle, ordered.items[3].status);
}

test "transition reorders and notifies exactly once" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 10),
        makeAgentInfo("p2", .idle, 5),
        makeAgentInfo("p3", .idle, 3),
        makeAgentInfo("p4", .idle, 1),
    };
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));
    // applySnapshot fires onChanged once
    try testing.expectEqual(@as(u32, 1), obs.changed_count);

    // #84: pane_updated no longer changes status. The test now verifies
    // that upsertAgent does NOT fire a transition — the truth comes from
    // session.snapshot via applySnapshot.
    const event_json =
        \\{"pane":{"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"blocked","revision":11}}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    const envelope = types.EventEnvelope{ .event = .pane_updated, .data = parsed.value };
    try store.applyEvent(envelope);

    // onTransition did NOT fire — upsertAgent no longer changes status
    try testing.expectEqual(@as(u32, 0), obs.transition_count);

    // Status unchanged
    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);

    // orderedAgents: p1 is still working (not blocked)
    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqual(types.AgentStatus.working, ordered.items[0].status);
    try testing.expectEqualStrings("p1", ordered.items[0].pane_id);
}

test "pane_closed removes agent; pane_updated for unknown pane NO crea uno" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{makeAgentInfo("p1", .idle, 1)};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    // pane_closed for p1
    const close_json =
        \\{"pane_id":"p1","workspace_id":"w1"}
    ;
    const close_parsed = try json.parseFromSlice(json.Value, testing.allocator, close_json, .{});
    defer close_parsed.deinit();
    try store.applyEvent(.{ .event = .pane_closed, .data = close_parsed.value });

    var ordered1 = try store.orderedAgents(testing.allocator);
    defer ordered1.deinit();
    try testing.expectEqual(@as(usize, 0), ordered1.items.len);

    // `pane_updated` de un pane desconocido NO crea nada: el payload no trae
    // ni `agent`, ni `title`, ni `cwd`, así que crearlo produciría una fila con
    // el `pane_id` pelado — el defecto que apareció al matar y relevantar el
    // servidor en el gate de integración. La identidad viene del snapshot.
    const update_json =
        \\{"pane":{"pane_id":"p9","terminal_id":"t2","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"working","revision":5}}
    ;
    const update_parsed = try json.parseFromSlice(json.Value, testing.allocator, update_json, .{});
    defer update_parsed.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = update_parsed.value });

    var ordered2 = try store.orderedAgents(testing.allocator);
    defer ordered2.deinit();
    try testing.expectEqual(@as(usize, 0), ordered2.items.len);
}

test "unknown agent_status goes to .unknown and sorts last" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 1),
    };
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    // pane_agent_status_changed with an unrecognized status value
    const event_json =
        \\{"pane_id":"p1","workspace_id":"w1","agent_status":"paused"}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_agent_status_changed, .data = parsed.value });

    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqual(@as(usize, 1), ordered.items.len);
    try testing.expectEqual(types.AgentStatus.unknown, ordered.items[0].status);
}

test "pane_focused moves focus without reordering by urgency" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 10),
        makeAgentInfo("p2", .working, 5),
    };
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    // pane_focused for p1
    const event_json =
        \\{"pane_id":"p1","workspace_id":"w1"}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    const changed_before = obs.changed_count;
    try store.applyEvent(.{ .event = .pane_focused, .data = parsed.value });

    // onChanged fired (but no onTransition — status didn't change)
    try testing.expect(obs.changed_count > changed_before);
    try testing.expect(obs.last_transition_from == null);

    // p1 focused, p2 not
    const key1 = AgentKey{ .device_id = "local", .pane_id = "p1" };
    const key2 = AgentKey{ .device_id = "local", .pane_id = "p2" };
    try testing.expect(store.agents.get(key1).?.focused);
    try testing.expect(!store.agents.get(key2).?.focused);

    // orderedAgents: same order (both working, p1 has higher revision)
    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqualStrings("p1", ordered.items[0].pane_id);
    try testing.expectEqualStrings("p2", ordered.items[1].pane_id);
}

test "no leaks: applySnapshot -> applyEvent -> deinit under testing.allocator" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    // Snapshot with 2 agents, 1 workspace, 1 tab
    const agents = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 1),
        makeAgentInfo("p2", .idle, 2),
    };
    const workspaces = [_]types.WorkspaceInfo{.{
        .workspace_id = "w1",
        .number = 1,
        .label = "main",
        .focused = true,
        .pane_count = 2,
        .tab_count = 1,
        .active_tab_id = "tab1",
        .agent_status = .working,
    }};
    const tabs = [_]types.TabInfo{.{
        .tab_id = "tab1",
        .workspace_id = "w1",
        .number = 1,
        .label = "Tab 1",
        .focused = true,
        .pane_count = 2,
        .agent_status = .working,
    }};
    try store.applySnapshot(makeSnapshot(&agents, &workspaces, &tabs));

    // pane_updated p1 — #84: no longer changes status
    const ev1_json =
        \\{"pane":{"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"blocked","revision":3}}
    ;
    const ev1 = try json.parseFromSlice(json.Value, testing.allocator, ev1_json, .{});
    defer ev1.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = ev1.value });

    // pane_closed p2
    const ev2_json =
        \\{"pane_id":"p2","workspace_id":"w1"}
    ;
    const ev2 = try json.parseFromSlice(json.Value, testing.allocator, ev2_json, .{});
    defer ev2.deinit();
    try store.applyEvent(.{ .event = .pane_closed, .data = ev2.value });

    // pane_created p3
    const ev3_json =
        \\{"pane":{"pane_id":"p3","terminal_id":"t3","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"done","revision":1}}
    ;
    const ev3 = try json.parseFromSlice(json.Value, testing.allocator, ev3_json, .{});
    defer ev3.deinit();
    try store.applyEvent(.{ .event = .pane_created, .data = ev3.value });

    // workspace_renamed
    const ev4_json =
        \\{"workspace_id":"w1","label":"renamed"}
    ;
    const ev4 = try json.parseFromSlice(json.Value, testing.allocator, ev4_json, .{});
    defer ev4.deinit();
    try store.applyEvent(.{ .event = .workspace_renamed, .data = ev4.value });

    // tab_focused
    const ev5_json =
        \\{"tab_id":"tab1","workspace_id":"w1"}
    ;
    const ev5 = try json.parseFromSlice(json.Value, testing.allocator, ev5_json, .{});
    defer ev5.deinit();
    try store.applyEvent(.{ .event = .tab_focused, .data = ev5.value });

    // Estado final: 1 agente. `p1` sigue (el snapshot lo trajo) y su status
    // NO cambió por pane.updated (#84); `p2` se cerró; y `p3` NO entra,
    // porque un evento de pane ya no crea agentes — no trae su identidad.
    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqual(@as(usize, 1), ordered.items.len);
    // #84: status unchanged — upsertAgent no longer touches it
    try testing.expectEqual(types.AgentStatus.working, ordered.items[0].status);
    try testing.expectEqualStrings("p1", ordered.items[0].pane_id);

    // Workspace renamed
    var ws_it = store.workspaces.iterator();
    while (ws_it.next()) |entry| {
        try testing.expectEqualStrings("renamed", entry.value_ptr.label);
    }

    // deinit() frees everything — testing.allocator catches leaks.
}

test "pane_agent_status_changed does not create unknown pane" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const event_json =
        \\{"pane_id":"unknown_pane","workspace_id":"w1","agent_status":"working"}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_agent_status_changed, .data = parsed.value });

    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqual(@as(usize, 0), ordered.items.len);
}

test "displayTitle falls back through title chain" {
    const agent = Agent{
        .device_id = "local",
        .pane_id = "p1",
        .workspace_id = "w1",
        .tab_id = "tab1",
        .status = .idle,
        .revision = 0,
        .focused = false,
    };
    // All null: falls back to pane_id
    try testing.expectEqualStrings("p1", agent.displayTitle());

    // With agent set
    const with_agent = Agent{
        .device_id = "local",
        .pane_id = "p1",
        .workspace_id = "w1",
        .tab_id = "tab1",
        .status = .idle,
        .revision = 0,
        .focused = false,
        .agent = "claude",
    };
    try testing.expectEqualStrings("claude", with_agent.displayTitle());

    // With title set (highest priority)
    const with_title = Agent{
        .device_id = "local",
        .pane_id = "p1",
        .workspace_id = "w1",
        .tab_id = "tab1",
        .status = .idle,
        .revision = 0,
        .focused = false,
        .agent = "claude",
        .title = "My Agent",
    };
    try testing.expectEqualStrings("My Agent", with_title.displayTitle());
}

test "applySnapshot replaces previous state cleanly" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // First snapshot: 2 agents
    const agents1 = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 1),
        makeAgentInfo("p2", .idle, 2),
    };
    try store.applySnapshot(makeSnapshot(&agents1, &.{}, &.{}));
    try testing.expectEqual(@as(usize, 2), store.agents.count());

    // Second snapshot: 1 agent (p1 gone, p3 new)
    const agents2 = [_]types.AgentInfo{
        makeAgentInfo("p3", .done, 5),
    };
    try store.applySnapshot(makeSnapshot(&agents2, &.{}, &.{}));
    try testing.expectEqual(@as(usize, 1), store.agents.count());

    const key = AgentKey{ .device_id = "local", .pane_id = "p3" };
    try testing.expect(store.agents.get(key) != null);
    const key_p1 = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expect(store.agents.get(key_p1) == null);
}

test "two consecutive workspace_updated for same workspace_id do not double-free" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Seed with one workspace via snapshot.
    const workspaces = [_]types.WorkspaceInfo{.{
        .workspace_id = "w1",
        .number = 1,
        .label = "main",
        .focused = true,
        .pane_count = 1,
        .tab_count = 1,
        .active_tab_id = "tab1",
        .agent_status = .working,
    }};
    try store.applySnapshot(makeSnapshot(&.{}, &workspaces, &.{}));

    // First workspace_updated — replaces the existing entry.
    const ev1_json =
        \\{"workspace":{"workspace_id":"w1","number":1,"label":"main","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"tab1","agent_status":"working"}}
    ;
    const ev1 = try json.parseFromSlice(json.Value, testing.allocator, ev1_json, .{});
    defer ev1.deinit();
    try store.applyEvent(.{ .event = .workspace_updated, .data = ev1.value });

    // Second workspace_updated — must not crash (BUG 1 regression: the old
    // code freed old.key which is still live in the map → double free /
    // use-after-free on the next access).
    const ev2_json =
        \\{"workspace":{"workspace_id":"w1","number":1,"label":"updated","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"tab1","agent_status":"working"}}
    ;
    const ev2 = try json.parseFromSlice(json.Value, testing.allocator, ev2_json, .{});
    defer ev2.deinit();
    try store.applyEvent(.{ .event = .workspace_updated, .data = ev2.value });

    // Verify the label was updated to "updated".
    var ws_it = store.workspaces.iterator();
    while (ws_it.next()) |entry| {
        try testing.expectEqualStrings("updated", entry.value_ptr.label);
    }
    // deinit() frees everything — testing.allocator catches double-free / leaks.
}

test "pane_focused for unknown pane_id is a no-op (does not clear other agents' focus)" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Snapshot with one agent focused.
    const agents = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "w1",
        .tab_id = "tab1",
        .pane_id = "p1",
        .focused = true,
        .revision = 1,
    }};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    // pane_focused for a pane that does NOT exist in the store.
    const event_json =
        \\{"pane_id":"unknown_pane","workspace_id":"w1"}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_focused, .data = parsed.value });

    // p1 must still be focused — the unknown pane must not have cleared it.
    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expect(store.agents.get(key).?.focused);
}

test "pane_agent_status_changed without title preserves existing title" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Seed an agent whose displayTitle resolves via .title ("claude").
    const agents = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "w1",
        .tab_id = "tab1",
        .pane_id = "p1",
        .focused = false,
        .revision = 1,
        .agent = "claude",
        .title = "claude",
    }};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expectEqualStrings("claude", store.agents.get(key).?.displayTitle());

    // pane_agent_status_changed that only carries status — no title, no agent,
    // no display_agent.  Before the fix this would null out all three and
    // displayTitle() would fall back to pane_id ("p1").
    const event_json =
        \\{"pane_id":"p1","workspace_id":"w1","agent_status":"blocked"}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_agent_status_changed, .data = parsed.value });

    // Title must survive.
    try testing.expectEqualStrings("claude", store.agents.get(key).?.displayTitle());
    try testing.expectEqualStrings("claude", store.agents.get(key).?.title.?);
    // Status did change.
    try testing.expectEqual(types.AgentStatus.blocked, store.agents.get(key).?.status);
}

test "ningun evento de pane crea un agente: la identidad viene del snapshot" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Un pane normal (una shell): herdr lo manda con agent_status "unknown" y
    // sin campo `agent`. Antes de la guarda esto creaba una fila fantasma.
    const shell_json =
        \\{"pane":{"pane_id":"w3:p3","terminal_id":"t3","workspace_id":"w3","tab_id":"w3:t4","focused":false,"agent_status":"unknown","revision":1}}
    ;
    const shell = try json.parseFromSlice(json.Value, testing.allocator, shell_json, .{});
    defer shell.deinit();
    try store.applyEvent(.{ .event = .pane_created, .data = shell.value });
    try testing.expectEqual(@as(usize, 0), store.agents.count());

    // Y tampoco uno que sí hospeda un agente: el evento no trae su identidad.
    // Aparecerá cuando llegue el snapshot, que es quien la tiene.
    const agent_json =
        \\{"pane":{"pane_id":"w5:p1","terminal_id":"t1","workspace_id":"w5","tab_id":"w5:t1","focused":false,"agent_status":"idle","revision":1}}
    ;
    const ag = try json.parseFromSlice(json.Value, testing.allocator, agent_json, .{});
    defer ag.deinit();
    try store.applyEvent(.{ .event = .pane_created, .data = ag.value });
    try testing.expectEqual(@as(usize, 0), store.agents.count());
}

test "el replay no degrada a unknown, pero un cambio de estado real SI se aplica" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "wA",
        .tab_id = "wA:t3",
        .pane_id = "wA:p5",
        .focused = false,
        .revision = 11,
    }};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));
    const key = AgentKey{ .device_id = "local", .pane_id = "wA:p5" };
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);

    // 1) El replay del historial llega con `unknown` y revisión vieja. Un pane
    //    que ya demostró alojar un agente no deja de alojarlo por una trama
    //    vieja: el estado se conserva.
    const replay =
        \\{"pane":{"pane_id":"wA:p5","terminal_id":"t1","workspace_id":"wA","tab_id":"wA:t3","focused":false,"agent_status":"unknown","revision":1}}
    ;
    const old_ev = try json.parseFromSlice(json.Value, testing.allocator, replay, .{});
    defer old_ev.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = old_ev.value });
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);

    // 2) #84: upsertAgent ya NO es fuente de estado. Un pane.updated que
    //    cambia agent_status NO modifica el status del agente en el Store.
    //    La verdad viene de session.snapshot vía applySnapshot.
    const change =
        \\{"pane":{"pane_id":"wA:p5","terminal_id":"t1","workspace_id":"wA","tab_id":"wA:t3","focused":false,"agent_status":"blocked","revision":11}}
    ;
    const ev = try json.parseFromSlice(json.Value, testing.allocator, change, .{});
    defer ev.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = ev.value });
    // Status unchanged — upsertAgent no longer touches it
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);
}

// ---------------------------------------------------------------------------
// #84: New tests — exact names from the design
// ---------------------------------------------------------------------------

test "upsertAgent: un pane.updated NO cambia el status del agente" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{makeAgentInfo("p1", .working, 10)};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);

    // pane_updated with different agent_status
    const event_json =
        \\{"pane":{"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"blocked","revision":11}}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = parsed.value });

    // Status must NOT change — upsertAgent is no longer a source of status
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);
}

test "upsertAgent: un pane.updated SI actualiza workspace/tab/focused" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const agents = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "w1",
        .tab_id = "tab1",
        .pane_id = "p1",
        .focused = false,
        .revision = 10,
    }};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));

    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expectEqualStrings("w1", store.agents.get(key).?.workspace_id);
    try testing.expectEqualStrings("tab1", store.agents.get(key).?.tab_id);
    try testing.expect(!store.agents.get(key).?.focused);

    // pane_updated with different workspace, tab, and focused
    const event_json =
        \\{"pane":{"pane_id":"p1","terminal_id":"t1","workspace_id":"w2","tab_id":"tab2","focused":true,"agent_status":"working","revision":11}}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = parsed.value });

    // Structural fields must update
    try testing.expectEqualStrings("w2", store.agents.get(key).?.workspace_id);
    try testing.expectEqualStrings("tab2", store.agents.get(key).?.tab_id);
    try testing.expect(store.agents.get(key).?.focused);
    // Status unchanged
    try testing.expectEqual(types.AgentStatus.working, store.agents.get(key).?.status);
}

test "upsertAgent: un pane.updated que solo cambia revision NO dispara onChanged" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents = [_]types.AgentInfo{makeAgentInfo("p1", .working, 10)};
    try store.applySnapshot(makeSnapshot(&agents, &.{}, &.{}));
    const changed_before = obs.changed_count;

    // pane_updated with only revision changed (same workspace, tab, focused)
    const event_json =
        \\{"pane":{"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"working","revision":11}}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = parsed.value });

    // onChanged must NOT fire — only revision changed, which is terminal output noise
    try testing.expectEqual(changed_before, obs.changed_count);
}

test "applySnapshot: un snapshot con la misma huella no dispara onChanged" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 10),
        makeAgentInfo("p2", .idle, 5),
    };
    const workspaces = [_]types.WorkspaceInfo{.{
        .workspace_id = "w1",
        .number = 1,
        .label = "main",
        .focused = true,
        .pane_count = 2,
        .tab_count = 1,
        .active_tab_id = "tab1",
        .agent_status = .working,
    }};
    try store.applySnapshot(makeSnapshot(&agents, &workspaces, &.{}));
    try testing.expectEqual(@as(u32, 1), obs.changed_count);

    // Apply the exact same snapshot again
    try store.applySnapshot(makeSnapshot(&agents, &workspaces, &.{}));

    // onChanged must NOT fire a second time — fingerprint is identical
    try testing.expectEqual(@as(u32, 1), obs.changed_count);
}

test "applySnapshot: revision distinta no cuenta como cambio" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents1 = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 10),
    };
    try store.applySnapshot(makeSnapshot(&agents1, &.{}, &.{}));
    try testing.expectEqual(@as(u32, 1), obs.changed_count);

    // Same agent, same status, but different revision (terminal output)
    const agents2 = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 11),
    };
    try store.applySnapshot(makeSnapshot(&agents2, &.{}, &.{}));

    // onChanged must NOT fire — revision is excluded from fingerprint
    try testing.expectEqual(@as(u32, 1), obs.changed_count);
}

test "applySnapshot: un cambio de agent_status SI dispara onChanged" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents1 = [_]types.AgentInfo{
        makeAgentInfo("p1", .working, 10),
    };
    try store.applySnapshot(makeSnapshot(&agents1, &.{}, &.{}));
    try testing.expectEqual(@as(u32, 1), obs.changed_count);

    // Same agent but different status
    const agents2 = [_]types.AgentInfo{
        makeAgentInfo("p1", .blocked, 10),
    };
    try store.applySnapshot(makeSnapshot(&agents2, &.{}, &.{}));

    // onChanged must fire — agent_status changed
    try testing.expectEqual(@as(u32, 2), obs.changed_count);
    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expectEqual(types.AgentStatus.blocked, store.agents.get(key).?.status);
}

test "applySnapshot: un cambio de titulo/label SI dispara onChanged" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var obs = TestObserver{};
    try store.addObserver(obs.observer());

    const agents1 = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "w1",
        .tab_id = "tab1",
        .pane_id = "p1",
        .focused = false,
        .revision = 10,
        .title = "old title",
    }};
    try store.applySnapshot(makeSnapshot(&agents1, &.{}, &.{}));
    try testing.expectEqual(@as(u32, 1), obs.changed_count);

    // Same agent but different title
    const agents2 = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "w1",
        .tab_id = "tab1",
        .pane_id = "p1",
        .focused = false,
        .revision = 10,
        .title = "new title",
    }};
    try store.applySnapshot(makeSnapshot(&agents2, &.{}, &.{}));

    // onChanged must fire — title changed
    try testing.expectEqual(@as(u32, 2), obs.changed_count);
    const key = AgentKey{ .device_id = "local", .pane_id = "p1" };
    try testing.expectEqualStrings("new title", store.agents.get(key).?.title.?);
}

test "computeFingerprint: campos adyacentes no se concatenan" {
    // Two snapshots where adjacent text fields are split differently:
    //   snapshot A: workspace_id="ab", tab_id="c"
    //   snapshot B: workspace_id="a",  tab_id="bc"
    // Without per-field separators these produce the same hash because
    // the byte sequences "ab" ++ "c" and "a" ++ "bc" are identical.
    // workspace_id and tab_id are adjacent in the hash (no non-text field
    // between them).

    const agents_a = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "ab",
        .tab_id = "c",
        .pane_id = "p1",
        .focused = false,
        .revision = 1,
    }};
    const snap_a = makeSnapshot(&agents_a, &.{}, &.{});

    const agents_b = [_]types.AgentInfo{.{
        .terminal_id = "t1",
        .agent_status = .working,
        .workspace_id = "a",
        .tab_id = "bc",
        .pane_id = "p1",
        .focused = false,
        .revision = 1,
    }};
    const snap_b = makeSnapshot(&agents_b, &.{}, &.{});

    const fp_a = Store.computeFingerprint(snap_a);
    const fp_b = Store.computeFingerprint(snap_b);

    try testing.expect(fp_a != fp_b);
}
