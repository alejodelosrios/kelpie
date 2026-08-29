const std = @import("std");
const Io = std.Io;
const json = std.json;
const client = @import("client.zig");
const types = @import("types.zig");

const log = std.log.scoped(.herdr_probe);

/// Entry point for `kelpie --herdr-probe`.
/// Runs all five demonstrations against the live herdr socket.
pub fn run(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = client.resolveSocketPath(init.environ_map.*, &path_buf) catch |err| {
        try stdout.interface.print("error: cannot resolve socket path: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
        return;
    };

    try stdout.interface.print("herdr probe — socket: {s}\n\n", .{socket_path});
    try stdout.interface.flush();

    const gpa = init.gpa;

    // 1. ping
    demoPing(init.io, socket_path, gpa, &stdout) catch |err| {
        try stdout.interface.print("  ping FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    // 2. session.snapshot
    demoSessionSnapshot(init.io, socket_path, gpa, &stdout) catch |err| {
        try stdout.interface.print("  session.snapshot FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    // 3. agent.list
    demoAgentList(init.io, socket_path, gpa, &stdout) catch |err| {
        try stdout.interface.print("  agent.list FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    // 4. events.subscribe (persistent stream)
    demoEventsSubscribe(init.io, socket_path, &stdout) catch |err| {
        try stdout.interface.print("  events.subscribe FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    // 5a. error: id not a string
    demoErrorIdNotString(init.io, socket_path, gpa, &stdout) catch |err| {
        try stdout.interface.print("  error-id-not-string FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    // 5b. error: params missing
    demoErrorParamsMissing(init.io, socket_path, gpa, &stdout) catch |err| {
        try stdout.interface.print("  error-params-missing FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    // 5c. second request on same connection fails
    demoSecondRequestFails(init.io, socket_path, &stdout) catch |err| {
        try stdout.interface.print("  second-request-fails FAILED: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
    };

    try stdout.interface.print("\nherdr probe done.\n", .{});
    try stdout.interface.flush();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const Request = struct {
    id: []const u8,
    method: []const u8,
    params: struct {},
};

fn sendAndParse(
    conn: *client.Connection,
    request: Request,
    gpa: std.mem.Allocator,
) !json.Parsed(json.Value) {
    const line = try conn.sendRequest(request);
    return json.parseFromSlice(json.Value, gpa, line, .{ .ignore_unknown_fields = true });
}

// ---------------------------------------------------------------------------
// 1. ping → pong with protocol >= 20
// ---------------------------------------------------------------------------

fn demoPing(io: Io, socket_path: []const u8, gpa: std.mem.Allocator, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("[1] ping → pong\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    const parsed = try sendAndParse(&conn, .{
        .id = "1",
        .method = "ping",
        .params = .{},
    }, gpa);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse {
        try stdout.interface.print("  FAIL: no 'result' in response\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const rtype = result.object.get("type") orelse {
        try stdout.interface.print("  FAIL: no 'type' in result\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    if (rtype != .string or !std.mem.eql(u8, rtype.string, "pong")) {
        try stdout.interface.print("  FAIL: expected type='pong', got {any}\n", .{rtype});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    }

    const protocol = result.object.get("protocol") orelse {
        try stdout.interface.print("  FAIL: no 'protocol' in result\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const proto_val: i64 = switch (protocol) {
        .integer => |i| i,
        else => {
            try stdout.interface.print("  FAIL: protocol is not an integer: {any}\n", .{protocol});
            try stdout.interface.flush();
            return error.UnexpectedResponse;
        },
    };

    if (proto_val < 20) {
        try stdout.interface.print("  FAIL: protocol {d} < 20\n", .{proto_val});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    }

    try stdout.interface.print("  OK: pong, protocol={d}\n", .{proto_val});
    try stdout.interface.flush();
}

// ---------------------------------------------------------------------------
// 2. session.snapshot → count workspaces, tabs, panes, active agents
// ---------------------------------------------------------------------------

fn demoSessionSnapshot(io: Io, socket_path: []const u8, gpa: std.mem.Allocator, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("\n[2] session.snapshot\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    const parsed = try sendAndParse(&conn, .{
        .id = "1",
        .method = "session.snapshot",
        .params = .{},
    }, gpa);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse {
        try stdout.interface.print("  FAIL: no 'result'\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const snapshot = result.object.get("snapshot") orelse {
        try stdout.interface.print("  FAIL: no 'snapshot' in result\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const workspaces = snapshot.object.get("workspaces") orelse {
        try stdout.interface.print("  FAIL: no 'workspaces' in snapshot\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    var total_tabs: i64 = 0;
    var total_panes: i64 = 0;

    if (workspaces == .array) {
        for (workspaces.array.items) |ws| {
            if (ws.object.get("tab_count")) |tc| {
                if (tc == .integer) total_tabs += tc.integer;
            }
            if (ws.object.get("pane_count")) |pc| {
                if (pc == .integer) total_panes += pc.integer;
            }
        }
    }

    try stdout.interface.print("  workspaces: {d}, tabs: {d}, panes: {d}\n", .{
        if (workspaces == .array) workspaces.array.items.len else 0,
        total_tabs,
        total_panes,
    });
    try stdout.interface.flush();
}

// ---------------------------------------------------------------------------
// 3. agent.list → print pane_id, agent, agent_status per agent
// ---------------------------------------------------------------------------

fn demoAgentList(io: Io, socket_path: []const u8, gpa: std.mem.Allocator, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("\n[3] agent.list\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    const parsed = try sendAndParse(&conn, .{
        .id = "1",
        .method = "agent.list",
        .params = .{},
    }, gpa);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse {
        try stdout.interface.print("  FAIL: no 'result'\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const agents = result.object.get("agents") orelse {
        try stdout.interface.print("  FAIL: no 'agents' in result\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    if (agents != .array or agents.array.items.len == 0) {
        try stdout.interface.print("  (no agents)\n", .{});
        try stdout.interface.flush();
        return;
    }

    // Declared once outside the loop and reused per-iteration: `pane_str` for
    // the `.integer` case is a slice into this buffer, and it must still be
    // valid at the `print` below — an `int_buf` declared inside the `blk:`
    // scope would close before that use, the same class of dangling-slice UB
    // as the Connection.open buffer-lifetime bug this issue's Apply hit.
    var int_buf: [32]u8 = undefined;
    for (agents.array.items) |agent| {
        const pane_id = agent.object.get("pane_id") orelse .null;
        const agent_name = agent.object.get("agent") orelse .null;
        const status = agent.object.get("agent_status") orelse .null;

        const pane_str = switch (pane_id) {
            .string => |s| s,
            .integer => |i| std.fmt.bufPrint(&int_buf, "{d}", .{i}) catch "?",
            else => "?",
        };
        const agent_str = switch (agent_name) {
            .string => |s| s,
            else => "?",
        };
        const status_str = switch (status) {
            .string => |s| s,
            else => "?",
        };

        try stdout.interface.print("  pane={s}  agent={s}  status={s}\n", .{ pane_str, agent_str, status_str });
        try stdout.interface.flush();
    }
}

// ---------------------------------------------------------------------------
// 4. events.subscribe → ack + 5 raw event lines
// ---------------------------------------------------------------------------

fn demoEventsSubscribe(io: Io, socket_path: []const u8, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("\n[4] events.subscribe (5 events)\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    // Send subscribe request. Subscriptions without params (just {"type":"..."})
    // from the schema: workspace.*, worktree.*, tab.*, pane.updated, layout.updated.
    const subscribe_json =
        \\{"id":"1","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.updated"},{"type":"layout.updated"},{"type":"workspace.created"},{"type":"workspace.closed"},{"type":"tab.created"},{"type":"tab.closed"}]}}
    ;
    try conn.writer.interface.writeAll(subscribe_json);
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    // Read ack line. This connection stays open for more reads (the events
    // that follow), so we must consume the '\n' delimiter itself — with
    // takeDelimiterExclusive the delimiter is left in the buffer and the next
    // call re-finds it instantly, returning "" without ever reading more data.
    const ack_line = try takeLine(&conn.reader.interface);
    try stdout.interface.print("  ack: {s}\n", .{ack_line});
    try stdout.interface.flush();

    // Read 5 event lines.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const event_line = takeLine(&conn.reader.interface) catch |err| {
            try stdout.interface.print("  event {d}: read error: {s}\n", .{ i + 1, @errorName(err) });
            try stdout.interface.flush();
            break;
        };
        try stdout.interface.print("  event {d}: {s}\n", .{ i + 1, event_line });
        try stdout.interface.flush();
    }
}

/// Read one NDJSON line and consume its trailing '\n', for readers that keep
/// reading more lines afterwards (unlike `Connection.sendRequest`, which
/// reads exactly once before the connection closes).
fn takeLine(r: *std.Io.Reader) ![]u8 {
    const line = try r.takeDelimiterInclusive('\n');
    return line[0 .. line.len - 1];
}

// Zig's test runner only discovers `test` blocks in the root source file
// plus whatever gets explicitly referenced from a `test {}` block — it does
// NOT walk `@import`s transitively (verified against zig 0.16.0). Without
// this, `client.zig`'s tests would silently never run under `zig build test`.
test {
    _ = client;
    _ = types;
}

// ---------------------------------------------------------------------------
// 5a. error: id not a string → invalid_request
// ---------------------------------------------------------------------------

fn demoErrorIdNotString(io: Io, socket_path: []const u8, gpa: std.mem.Allocator, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("\n[5a] error: id not a string\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    // Send raw JSON with numeric id.
    const bad_request =
        \\{"id":1,"method":"ping","params":{}}
    ;
    try conn.writer.interface.writeAll(bad_request);
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    const line = try conn.reader.interface.takeDelimiterExclusive('\n');

    const parsed = json.parseFromSlice(json.Value, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| {
        try stdout.interface.print("  FAIL: cannot parse response: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
        return;
    };
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error") orelse {
        try stdout.interface.print("  FAIL: no 'error' in response\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const code = err_obj.object.get("code") orelse .null;
    const code_str = switch (code) {
        .string => |s| s,
        else => "?",
    };

    if (std.mem.eql(u8, code_str, "invalid_request")) {
        try stdout.interface.print("  OK: error.code = \"{s}\"\n", .{code_str});
    } else {
        try stdout.interface.print("  FAIL: expected 'invalid_request', got \"{s}\"\n", .{code_str});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    }
    try stdout.interface.flush();
}

// ---------------------------------------------------------------------------
// 5b. error: params missing → invalid_request
// ---------------------------------------------------------------------------

fn demoErrorParamsMissing(io: Io, socket_path: []const u8, gpa: std.mem.Allocator, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("\n[5b] error: params missing\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    // Send raw JSON without params field.
    const bad_request =
        \\{"id":"1","method":"ping"}
    ;
    try conn.writer.interface.writeAll(bad_request);
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    const line = try conn.reader.interface.takeDelimiterExclusive('\n');

    const parsed = json.parseFromSlice(json.Value, gpa, line, .{ .ignore_unknown_fields = true }) catch |err| {
        try stdout.interface.print("  FAIL: cannot parse response: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
        return;
    };
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error") orelse {
        try stdout.interface.print("  FAIL: no 'error' in response\n", .{});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    };

    const code = err_obj.object.get("code") orelse .null;
    const code_str = switch (code) {
        .string => |s| s,
        else => "?",
    };

    if (std.mem.eql(u8, code_str, "invalid_request")) {
        try stdout.interface.print("  OK: error.code = \"{s}\"\n", .{code_str});
    } else {
        try stdout.interface.print("  FAIL: expected 'invalid_request', got \"{s}\"\n", .{code_str});
        try stdout.interface.flush();
        return error.UnexpectedResponse;
    }
    try stdout.interface.flush();
}

// ---------------------------------------------------------------------------
// 5c. second request on same connection → EPIPE/EOF (expected behavior)
// ---------------------------------------------------------------------------

fn demoSecondRequestFails(io: Io, socket_path: []const u8, stdout: *std.Io.File.Writer) !void {
    try stdout.interface.print("\n[5c] second request on same connection → EPIPE/EOF\n", .{});
    try stdout.interface.flush();

    var conn: client.Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();

    // First request succeeds.
    const first =
        \\{"id":"1","method":"ping","params":{}}
    ;
    try conn.writer.interface.writeAll(first);
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    // Read the response (discard). Must consume the trailing '\n' itself
    // (takeLine, not takeDelimiterExclusive) or the peek below re-finds that
    // leftover delimiter instantly and wrongly reports the connection open.
    _ = takeLine(&conn.reader.interface) catch |err| {
        try stdout.interface.print("  FAIL: first request failed: {s}\n", .{@errorName(err)});
        try stdout.interface.flush();
        return;
    };

    // Second request — server should have closed the connection.
    // The server may close its write end but keep the read end open briefly,
    // or the kernel may buffer the write. Try reading first (should get EOF),
    // then try writing if read succeeds.
    const second =
        \\{"id":"2","method":"ping","params":{}}
    ;

    // Try to read first — if server closed, we should get EndOfStream.
    const peek_result = conn.reader.interface.peekDelimiterExclusive('\n');
    if (peek_result) |_| {
        // Server sent something unexpected, or connection is still open.
        // Try writing the second request.
        conn.writer.interface.writeAll(second) catch |write_err| {
            try stdout.interface.print("  OK: write of second request failed: {s} (expected)\n", .{@errorName(write_err)});
            try stdout.interface.flush();
            return;
        };
        conn.writer.interface.flush() catch |flush_err| {
            try stdout.interface.print("  OK: flush of second request failed: {s} (expected)\n", .{@errorName(flush_err)});
            try stdout.interface.flush();
            return;
        };

        // Write/flush succeeded — try reading (should fail).
        const read_result = conn.reader.interface.takeDelimiterExclusive('\n');
        if (read_result) |_| {
            try stdout.interface.print("  UNEXPECTED: second request succeeded\n", .{});
            try stdout.interface.flush();
            return error.UnexpectedResponse;
        } else |read_err| {
            try stdout.interface.print("  OK: read after second request failed: {s} (expected)\n", .{@errorName(read_err)});
            try stdout.interface.flush();
        }
    } else |peek_err| {
        // peek failed — server closed the connection (expected).
        try stdout.interface.print("  OK: peek after first response failed: {s} (expected — server closed connection)\n", .{@errorName(peek_err)});
        try stdout.interface.flush();
    }
}
