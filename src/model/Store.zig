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
                try upsertAgent(self, pane, true);
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

fn upsertAgent(self: *Store, pane: types.PaneInfo, allow_create: bool) !void {
    const key = AgentKey{
        .device_id = "local",
        .pane_id = pane.pane_id,
    };
    if (self.agents.getPtr(key)) |existing| {
        const from_status = existing.status;
        const duped_ws = try self.gpa.dupe(u8, pane.workspace_id);
        self.gpa.free(existing.workspace_id);
        existing.workspace_id = duped_ws;
        const duped_tab = try self.gpa.dupe(u8, pane.tab_id);
        self.gpa.free(existing.tab_id);
        existing.tab_id = duped_tab;
        existing.status = pane.agent_status;
        existing.revision = pane.revision;
        existing.focused = pane.focused;
        if (from_status != pane.agent_status) {
            fireTransition(&self.observers, existing, from_status, pane.agent_status);
        }
        fireChanged(&self.observers);
    } else if (allow_create and pane.agent_status != .unknown) {
        // `agent_status == .unknown` es la única señal que `PaneInfo` trae para
        // distinguir un pane que hospeda un agente de una shell cualquiera: el
        // payload de `pane.created`/`pane.updated` no incluye el campo `agent`.
        // Sin esta guarda el Store se llena de panes normales y el sidebar los
        // dibuja como filas sin título —`displayTitle` cae al `pane_id`—, que es
        // exactamente lo que apareció en el gate de integración: 14 filas para 7
        // agentes reales. Un agente que ya existe NO se borra si su status pasa a
        // `unknown`; la guarda es solo para crear.
        const duped_key = AgentKey{
            .device_id = try self.gpa.dupe(u8, "local"),
            .pane_id = try self.gpa.dupe(u8, pane.pane_id),
        };
        const agent = Agent{
            .device_id = duped_key.device_id,
            .pane_id = duped_key.pane_id,
            .workspace_id = try self.gpa.dupe(u8, pane.workspace_id),
            .tab_id = try self.gpa.dupe(u8, pane.tab_id),
            .status = pane.agent_status,
            .revision = pane.revision,
            .focused = pane.focused,
        };
        try self.agents.put(duped_key, agent);
        fireChanged(&self.observers);
    }
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

    // Build a pane_updated event that changes p1 to blocked.
    const event_json =
        \\{"pane":{"pane_id":"p1","terminal_id":"t1","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"blocked","revision":11}}
    ;
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, event_json, .{});
    defer parsed.deinit();
    const envelope = types.EventEnvelope{ .event = .pane_updated, .data = parsed.value };
    try store.applyEvent(envelope);

    // onTransition fired exactly once with working -> blocked
    try testing.expectEqual(@as(u32, 1), obs.transition_count);
    try testing.expectEqual(types.AgentStatus.working, obs.last_transition_from);
    try testing.expectEqual(types.AgentStatus.blocked, obs.last_transition_to);

    // orderedAgents: p1 is now first (blocked, rev 11)
    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqual(types.AgentStatus.blocked, ordered.items[0].status);
    try testing.expectEqualStrings("p1", ordered.items[0].pane_id);
}

test "pane_closed removes agent; pane_updated for unknown pane creates one" {
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

    // pane_updated for unknown p9 — creates it
    const update_json =
        \\{"pane":{"pane_id":"p9","terminal_id":"t2","workspace_id":"w1","tab_id":"tab1","focused":false,"agent_status":"working","revision":5}}
    ;
    const update_parsed = try json.parseFromSlice(json.Value, testing.allocator, update_json, .{});
    defer update_parsed.deinit();
    try store.applyEvent(.{ .event = .pane_updated, .data = update_parsed.value });

    var ordered2 = try store.orderedAgents(testing.allocator);
    defer ordered2.deinit();
    try testing.expectEqual(@as(usize, 1), ordered2.items.len);
    try testing.expectEqualStrings("p9", ordered2.items[0].pane_id);
    try testing.expectEqual(types.AgentStatus.working, ordered2.items[0].status);
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

    // pane_updated p1 -> blocked
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

    // Final state: 2 agents (p1 blocked, p3 done)
    var ordered = try store.orderedAgents(testing.allocator);
    defer ordered.deinit();
    try testing.expectEqual(@as(usize, 2), ordered.items.len);
    try testing.expectEqual(types.AgentStatus.blocked, ordered.items[0].status);
    try testing.expectEqual(types.AgentStatus.done, ordered.items[1].status);

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

test "pane.created for a non-agent pane does not create an agent row" {
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

    // Y el contrapunto: un pane que sí hospeda un agente sigue creándose.
    const agent_json =
        \\{"pane":{"pane_id":"w5:p1","terminal_id":"t1","workspace_id":"w5","tab_id":"w5:t1","focused":false,"agent_status":"idle","revision":1}}
    ;
    const ag = try json.parseFromSlice(json.Value, testing.allocator, agent_json, .{});
    defer ag.deinit();
    try store.applyEvent(.{ .event = .pane_created, .data = ag.value });
    try testing.expectEqual(@as(usize, 1), store.agents.count());
}
