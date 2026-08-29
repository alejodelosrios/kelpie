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
    type: []const u8,
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
// Required-field checker — shared by conformance and regression tests
// ---------------------------------------------------------------------------

const RequiredCheck = struct {
    /// Validates that every field listed in the schema's `required` array
    /// exists as a real field on the Zig struct `T`. `@hasField` can't take a
    /// runtime name, so this walks `@typeInfo(T).@"struct".fields` (comptime)
    /// and compares each field name against the runtime string — renames or
    /// missing fields in the struct are caught at test time either way.
    fn check(comptime T: type, defs_obj: json.Value, type_name: []const u8) !void {
        const def = defs_obj.object.get(type_name).?;
        const required = def.object.get("required").?;
        for (required.array.items) |item| {
            const name = item.string;
            var found = false;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    found = true;
                }
            }
            if (!found) return error.MissingStructField;
        }
    }
};

// ---------------------------------------------------------------------------
// Conformance test — validates types against testdata/herdr-api.schema.json
// ---------------------------------------------------------------------------

test "types match herdr-api.schema.json required fields and enum values" {
    const schema_bytes = @embedFile("testdata/herdr-api.schema.json");

    const parsed = try json.parseFromSlice(json.Value, testing.allocator, schema_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const schemas = root.get("schemas").?;
    const success_response = schemas.object.get("success_response").?;
    const defs = success_response.object.get("$defs").?;
    const event_schema = schemas.object.get("event").?;
    const event_defs = event_schema.object.get("$defs").?;

    // AgentInfo
    try RequiredCheck.check(AgentInfo, defs, "AgentInfo");

    // PaneInfo
    try RequiredCheck.check(PaneInfo, defs, "PaneInfo");

    // TabInfo
    try RequiredCheck.check(TabInfo, defs, "TabInfo");

    // WorkspaceInfo
    try RequiredCheck.check(WorkspaceInfo, defs, "WorkspaceInfo");

    // SessionSnapshot
    try RequiredCheck.check(SessionSnapshot, defs, "SessionSnapshot");

    // Pong (inline in ResponseResult.oneOf[0])
    const response_result = defs.object.get("ResponseResult").?;
    const one_of = response_result.object.get("oneOf").?;
    const pong_schema = one_of.array.items[0];
    const pong_required = pong_schema.object.get("required").?;
    for (pong_required.array.items) |item| {
        const name = item.string;
        var found = false;
        inline for (@typeInfo(Pong).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingStructField;
    }

    // EventEnvelope
    const event_envelope = event_schema;
    const event_required = event_envelope.object.get("required").?;
    for (event_required.array.items) |item| {
        const name = item.string;
        var found = false;
        inline for (@typeInfo(EventEnvelope).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.MissingStructField;
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

test "AgentStatus.unknown via parseFromValue" {
    // Exercises jsonParseFromValue — the real path used by client.zig's
    // Response = json.Parsed(json.Value).
    const value = json.Value{ .string = "paused" };
    const parsed = try json.parseFromValue(AgentStatus, testing.allocator, value, .{});
    defer parsed.deinit();
    try testing.expectEqual(AgentStatus.unknown, parsed.value);
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

test "required-field checker fails when a required field is renamed" {
    // Escenario Gherkin: "zig build test falla si se renombra un campo
    // requerido de AgentInfo" — la mitad negativa. Usa el RequiredCheck
    // compartido a nivel de archivo, no una copia local.
    const gpa = std.heap.page_allocator;
    const schema_bytes = @embedFile("testdata/herdr-api.schema.json");
    const parsed = try json.parseFromSlice(json.Value, gpa, schema_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const schemas = root.get("schemas").?;
    const success_response = schemas.object.get("success_response").?;
    const defs = success_response.object.get("$defs").?;

    // Build a modified defs where AgentInfo.required has "pane_id" renamed
    // to "pane_id_renamed" — the checker must fail because AgentInfo has no
    // such field.
    const agent_def = defs.object.get("AgentInfo").?;
    const original_required = agent_def.object.get("required").?;
    var modified_items: std.array_list.Managed(json.Value) = .init(testing.allocator);
    defer modified_items.deinit();
    for (original_required.array.items) |item| {
        const name = item.string;
        if (std.mem.eql(u8, name, "pane_id")) {
            try modified_items.append(.{ .string = "pane_id_renamed" });
        } else {
            try modified_items.append(item);
        }
    }

    // Create new maps (don't copy existing hashmap headers — that would
    // alias backing storage and cause subtle bugs when the original defs
    // is reused below).
    var modified_agent_map: json.ObjectMap = .empty;
    defer modified_agent_map.deinit(testing.allocator);
    try modified_agent_map.put(testing.allocator, "required", .{ .array = modified_items });

    var modified_defs_map: json.ObjectMap = .empty;
    defer modified_defs_map.deinit(testing.allocator);
    try modified_defs_map.put(testing.allocator, "AgentInfo", .{ .object = modified_agent_map });

    const result = RequiredCheck.check(AgentInfo, .{ .object = modified_defs_map }, "AgentInfo");
    try testing.expectError(error.MissingStructField, result);

    // The real (unmodified) defs still passes.
    try RequiredCheck.check(AgentInfo, defs, "AgentInfo");
}
