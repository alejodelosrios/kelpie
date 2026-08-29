const std = @import("std");
const json = std.json;
const testing = std.testing;

// ---------------------------------------------------------------------------
// AgentStatus — enum with .unknown fallback for future values
// ---------------------------------------------------------------------------

pub const AgentStatus = enum {
    idle,
    working,
    blocked,
    done,
    unknown,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !@This() {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeAllocated(allocator, token);
        const slice = switch (token) {
            inline .number, .allocated_number, .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(@This(), slice) orelse .unknown;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: json.Value, _: json.ParseOptions) !@This() {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(@This(), source.string) orelse .unknown;
    }
};

// ---------------------------------------------------------------------------
// EventKind — all values from the schema
// ---------------------------------------------------------------------------

pub const EventKind = enum {
    workspace_created,
    workspace_updated,
    workspace_metadata_updated,
    workspace_closed,
    workspace_renamed,
    workspace_moved,
    workspace_reordered,
    workspace_focused,
    worktree_created,
    worktree_opened,
    worktree_removed,
    tab_created,
    tab_closed,
    tab_renamed,
    tab_moved,
    tab_focused,
    pane_created,
    pane_closed,
    pane_updated,
    pane_focused,
    pane_moved,
    pane_output_changed,
    pane_exited,
    pane_agent_detected,
    pane_agent_status_changed,
    layout_updated,
};

// ---------------------------------------------------------------------------
// Structs — required fields only, optional fields with defaults
// ---------------------------------------------------------------------------

pub const AgentInfo = struct {
    terminal_id: []const u8,
    agent_status: AgentStatus,
    workspace_id: []const u8,
    tab_id: []const u8,
    pane_id: []const u8,
    focused: bool,
    revision: u64,
    // optional (design §"No entra": only required + the optional set the design lists)
    agent: ?[]const u8 = null,
    display_agent: ?[]const u8 = null,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    terminal_title: ?[]const u8 = null,
    terminal_title_stripped: ?[]const u8 = null,
    state_change_seq: u64 = 0,
};

pub const PaneInfo = struct {
    pane_id: []const u8,
    terminal_id: []const u8,
    workspace_id: []const u8,
    tab_id: []const u8,
    focused: bool,
    agent_status: AgentStatus,
    revision: u64,
};

pub const TabInfo = struct {
    tab_id: []const u8,
    workspace_id: []const u8,
    number: u32,
    label: []const u8,
    focused: bool,
    pane_count: u32,
    agent_status: AgentStatus,
};

pub const WorkspaceInfo = struct {
    workspace_id: []const u8,
    number: u32,
    label: []const u8,
    focused: bool,
    pane_count: u32,
    tab_count: u32,
    active_tab_id: []const u8,
    agent_status: AgentStatus,
};

pub const SessionSnapshot = struct {
    version: []const u8,
    protocol: u32,
    workspaces: []const WorkspaceInfo,
    tabs: []const TabInfo,
    panes: []const PaneInfo,
    layouts: []const json.Value,
    agents: []const AgentInfo,
    // optional
    focused_pane_id: ?[]const u8 = null,
    focused_tab_id: ?[]const u8 = null,
    focused_workspace_id: ?[]const u8 = null,
};

pub const Pong = struct {
    version: []const u8,
    protocol: u32,
    capabilities: ?json.Value = null,
};

pub const EventEnvelope = struct {
    event: EventKind,
    data: json.Value,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn freeAllocated(allocator: std.mem.Allocator, token: json.Scanner.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Conformance test — validates types against testdata/herdr-api.schema.json
// ---------------------------------------------------------------------------

test "types match herdr-api.schema.json required fields and enum values" {
    const gpa = std.heap.page_allocator;
    const schema_bytes = @embedFile("testdata/herdr-api.schema.json");

    const parsed = try json.parseFromSlice(json.Value, gpa, schema_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const schemas = root.get("schemas").?;
    const success_response = schemas.object.get("success_response").?;
    const defs = success_response.object.get("$defs").?;
    const event_schema = schemas.object.get("event").?;
    const event_defs = event_schema.object.get("$defs").?;

    // Helper: extract required field names from a schema definition.
    const RequiredCheck = struct {
        fn check(defs_obj: json.Value, type_name: []const u8, comptime fields: []const []const u8) !void {
            const def = defs_obj.object.get(type_name).?;
            const required = def.object.get("required").?;
            var schema_fields: [fields.len][]const u8 = undefined;
            for (required.array.items, 0..) |item, i| {
                schema_fields[i] = item.string;
            }
            inline for (fields) |expected| {
                var found = false;
                for (schema_fields) |actual| {
                    if (std.mem.eql(u8, actual, expected)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.MissingRequiredField;
            }
        }
    };

    // AgentInfo: 7 required fields
    try RequiredCheck.check(defs, "AgentInfo", &.{
        "terminal_id", "agent_status", "workspace_id", "tab_id", "pane_id", "focused", "revision",
    });

    // PaneInfo: 7 required fields
    try RequiredCheck.check(defs, "PaneInfo", &.{
        "pane_id", "terminal_id", "workspace_id", "tab_id", "focused", "agent_status", "revision",
    });

    // TabInfo: 7 required fields (all properties are required)
    try RequiredCheck.check(defs, "TabInfo", &.{
        "tab_id", "workspace_id", "number", "label", "focused", "pane_count", "agent_status",
    });

    // WorkspaceInfo: 8 required fields (all properties are required)
    try RequiredCheck.check(defs, "WorkspaceInfo", &.{
        "workspace_id", "number", "label", "focused", "pane_count", "tab_count", "active_tab_id", "agent_status",
    });

    // SessionSnapshot: 7 required fields
    try RequiredCheck.check(defs, "SessionSnapshot", &.{
        "version", "protocol", "workspaces", "tabs", "panes", "layouts", "agents",
    });

    // Pong (inline in ResponseResult.oneOf[0]): required = type, version, protocol
    const response_result = defs.object.get("ResponseResult").?;
    const one_of = response_result.object.get("oneOf").?;
    const pong_schema = one_of.array.items[0];
    const pong_required = pong_schema.object.get("required").?;
    const pong_fields = [_][]const u8{ "type", "version", "protocol" };
    for (pong_required.array.items, 0..) |item, i| {
        try testing.expectEqualStrings(pong_fields[i], item.string);
    }

    // EventEnvelope: required = event, data
    const event_envelope = event_schema;
    const event_required = event_envelope.object.get("required").?;
    const event_fields = [_][]const u8{ "event", "data" };
    for (event_required.array.items, 0..) |item, i| {
        try testing.expectEqualStrings(event_fields[i], item.string);
    }

    // AgentStatus enum: all values from schema
    const agent_status_schema = defs.object.get("AgentStatus").?;
    const agent_status_enum = agent_status_schema.object.get("enum").?;
    const expected_agent_status = [_][]const u8{ "idle", "working", "blocked", "done", "unknown" };
    try testing.expectEqual(expected_agent_status.len, agent_status_enum.array.items.len);
    for (expected_agent_status, agent_status_enum.array.items) |expected, actual| {
        try testing.expectEqualStrings(expected, actual.string);
    }

    // EventKind enum: all values from schema
    const event_kind_schema = event_defs.object.get("EventKind").?;
    const event_kind_enum = event_kind_schema.object.get("enum").?;
    const expected_event_kind = [_][]const u8{
        "workspace_created",          "workspace_updated",
        "workspace_metadata_updated", "workspace_closed",
        "workspace_renamed",          "workspace_moved",
        "workspace_reordered",        "workspace_focused",
        "worktree_created",           "worktree_opened",
        "worktree_removed",           "tab_created",
        "tab_closed",                 "tab_renamed",
        "tab_moved",                  "tab_focused",
        "pane_created",               "pane_closed",
        "pane_updated",               "pane_focused",
        "pane_moved",                 "pane_output_changed",
        "pane_exited",                "pane_agent_detected",
        "pane_agent_status_changed",  "layout_updated",
    };
    try testing.expectEqual(expected_event_kind.len, event_kind_enum.array.items.len);
    for (expected_event_kind, event_kind_enum.array.items) |expected, actual| {
        try testing.expectEqualStrings(expected, actual.string);
    }
}

test "AgentStatus.unknown absorbs unrecognized values" {
    const json_str = "{\"status\":\"paused\"}";
    const S = struct { status: AgentStatus };
    const parsed = try json.parseFromSlice(S, testing.allocator, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(AgentStatus.unknown, parsed.value.status);
}

test "AgentInfo optional fields default to null" {
    const json_str =
        \\{
        \\  "terminal_id": "t1",
        \\  "agent_status": "idle",
        \\  "workspace_id": "w1",
        \\  "tab_id": "tab1",
        \\  "pane_id": "p1",
        \\  "focused": true,
        \\  "revision": 1
        \\}
    ;
    const parsed = try json.parseFromSlice(AgentInfo, testing.allocator, json_str, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expect(parsed.value.agent == null);
    try testing.expect(parsed.value.display_agent == null);
    try testing.expect(parsed.value.name == null);
    try testing.expect(parsed.value.title == null);
    try testing.expect(parsed.value.cwd == null);
    try testing.expect(parsed.value.terminal_title == null);
    try testing.expect(parsed.value.terminal_title_stripped == null);
    try testing.expectEqual(0, parsed.value.state_change_seq);
}
