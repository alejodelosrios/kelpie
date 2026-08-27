const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const json = std.json;

/// Minimal NDJSON-RPC client over a Unix domain socket.
/// One request per connection (herdr closes after responding),
/// except for `events.subscribe` which keeps the stream open.
pub const Connection = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buf: [read_buf_size]u8 = undefined,
    write_buf: [write_buf_size]u8 = undefined,

    const read_buf_size = 64 * 1024;
    const write_buf_size = 64 * 1024;

    /// Open a connection to the herdr Unix socket.
    /// `socket_path` must be ≤ 108 bytes (UnixAddress.max_len).
    ///
    /// `self` is an out-parameter: the caller must have already placed it at
    /// its final memory address (e.g. a local `var`) before calling `open`,
    /// and must never move/copy it afterwards. `reader`/`writer` build a
    /// `net.Stream.Reader`/`Writer` whose `.interface.buffer` points at
    /// `self.read_buf`/`self.write_buf` — if `self` moves, those become
    /// dangling pointers.
    pub fn open(self: *Connection, io: Io, socket_path: []const u8) !void {
        const addr = try net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        errdefer stream.close(io);

        self.stream = stream;
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        self.stream.close(self.reader.io);
    }

    /// Send a JSON request and read one JSON response line.
    /// Returns the raw response line (caller owns nothing — buffer is internal).
    pub fn sendRequest(
        self: *Connection,
        request: anytype,
    ) ![]u8 {
        // Serialize request to the writer buffer, then flush.
        try json.Stringify.value(request, .{}, &self.writer.interface);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();

        // Read one NDJSON line from the server.
        return self.reader.interface.takeDelimiterExclusive('\n');
    }
};

/// Resolve the herdr socket path from environment or default.
/// Returns `HERDR_SOCKET_PATH` verbatim (a slice into `environ`'s own
/// storage) if set, otherwise builds `$HOME/.config/herdr/herdr.sock` into
/// `buf`. The returned slice's lifetime differs per branch — copy it out
/// immediately if you need it to outlive `environ`.
pub fn resolveSocketPath(
    environ: std.process.Environ.Map,
    buf: *[std.fs.max_path_bytes]u8,
) ![]const u8 {
    if (environ.get("HERDR_SOCKET_PATH")) |p| return p;

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const suffix = "/.config/herdr/herdr.sock";
    if (home.len + suffix.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    return buf[0 .. home.len + suffix.len];
}

// ---------------------------------------------------------------------------
// Tests — Gherkin scenarios from roadmap/designs/5-spike-d-herdr-rpc.md
//
// These open real connections against the live herdr socket. They skip (not
// fail) when the environment isn't a herdr session, so `zig build test`
// stays green on machines/CI without a live socket.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Resolve the live socket path from the real process environment, or skip
/// the calling test if this isn't a herdr session (mirrors the same gate
/// `main.zig` applies before calling the probe).
fn liveSocketPathOrSkip(buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    var env_map = try std.process.Environ.createMap(testing.environ, testing.allocator);
    defer env_map.deinit();

    if (env_map.get("HERDR_ENV") == null) return error.SkipZigTest;

    // `resolveSocketPath` only writes into `buf` on the HOME-fallback path —
    // when HERDR_SOCKET_PATH is set it returns a slice aliasing env_map's own
    // storage. Copy into `buf` ourselves so the path outlives `env_map`,
    // which we free (via `defer` above) before the caller connects.
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = resolveSocketPath(env_map, &scratch) catch return error.SkipZigTest;
    @memcpy(buf[0..resolved.len], resolved);
    return buf[0..resolved.len];
}

/// Out-parameter, not a return-by-value: `Connection.open` fixes
/// `reader`/`writer` buffer pointers at `conn`'s address, so `conn` must
/// already live at its final memory location before this is called (same
/// contract as `Connection.open` itself — see its doc-comment).
fn openLive(conn: *Connection, buf: *[std.fs.max_path_bytes]u8) !void {
    const path = try liveSocketPathOrSkip(buf);

    conn.open(testing.io, path) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest; // no live socket here
        return err; // any other failure is a real test failure
    };
}

test "ping responds pong with protocol >= 20" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    // Regression check: `Connection.open` fixes `reader.interface.buffer` to
    // point at `conn.read_buf`'s address. If `openLive` ever goes back to
    // returning `Connection` by value (copying it out of a dead stack frame)
    // this pointer stops matching the copy's own `read_buf`.
    try testing.expectEqual(@intFromPtr(&conn.read_buf), @intFromPtr(conn.reader.interface.buffer.ptr));

    const line = try conn.sendRequest(.{ .id = "1", .method = "ping", .params = .{} });
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.UnexpectedResponse;
    const rtype = result.object.get("type") orelse return error.UnexpectedResponse;
    try testing.expect(rtype == .string);
    try testing.expectEqualStrings("pong", rtype.string);

    const protocol = result.object.get("protocol") orelse return error.UnexpectedResponse;
    try testing.expect(protocol == .integer);
    try testing.expect(protocol.integer >= 20);
}

test "session.snapshot returns workspaces with tab_count and pane_count" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    const line = try conn.sendRequest(.{ .id = "1", .method = "session.snapshot", .params = .{} });
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.UnexpectedResponse;
    const snapshot = result.object.get("snapshot") orelse return error.UnexpectedResponse;
    const workspaces = snapshot.object.get("workspaces") orelse return error.UnexpectedResponse;
    try testing.expect(workspaces == .array);

    // Every workspace entry must carry the counters the probe totals up.
    for (workspaces.array.items) |ws| {
        const tc = ws.object.get("tab_count") orelse return error.UnexpectedResponse;
        const pc = ws.object.get("pane_count") orelse return error.UnexpectedResponse;
        try testing.expect(tc == .integer);
        try testing.expect(pc == .integer);
    }
}

test "agent.list entries carry pane_id, agent and agent_status" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    const line = try conn.sendRequest(.{ .id = "1", .method = "agent.list", .params = .{} });
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.UnexpectedResponse;
    const agents = result.object.get("agents") orelse return error.UnexpectedResponse;
    try testing.expect(agents == .array);

    // The task environment has active agents; assert the shape is real, not vacuous.
    try testing.expect(agents.array.items.len > 0);

    const allowed_status = [_][]const u8{ "idle", "working", "blocked", "done", "unknown" };
    for (agents.array.items) |agent| {
        try testing.expect(agent.object.get("pane_id") != null);
        try testing.expect(agent.object.get("agent") != null);
        const status = agent.object.get("agent_status") orelse return error.UnexpectedResponse;
        try testing.expect(status == .string);
        var found = false;
        for (allowed_status) |s| {
            if (std.mem.eql(u8, status.string, s)) found = true;
        }
        try testing.expect(found);
    }
}

test "a non-string id is rejected as invalid_request" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    try conn.writer.interface.writeAll(
        \\{"id":1,"method":"ping","params":{}}
    );
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    const line = try conn.reader.interface.takeDelimiterExclusive('\n');
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error") orelse return error.UnexpectedResponse;
    const code = err_obj.object.get("code") orelse return error.UnexpectedResponse;
    try testing.expect(code == .string);
    try testing.expectEqualStrings("invalid_request", code.string);
}

test "a request missing params is rejected as invalid_request" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    try conn.writer.interface.writeAll(
        \\{"id":"1","method":"ping"}
    );
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    const line = try conn.reader.interface.takeDelimiterExclusive('\n');
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const err_obj = parsed.value.object.get("error") orelse return error.UnexpectedResponse;
    const code = err_obj.object.get("code") orelse return error.UnexpectedResponse;
    try testing.expect(code == .string);
    try testing.expectEqualStrings("invalid_request", code.string);
}

test "a second non-subscription request on the same connection fails" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    // First request succeeds. Written by hand (not `sendRequest`) so we can
    // drain the response with `takeLine`: `sendRequest` deliberately uses
    // `takeDelimiterExclusive`, which is correct for its one-shot-connection
    // contract but leaves the '\n' in the buffer — reusing the connection for
    // a second read would instantly re-find that leftover delimiter and
    // return "" without ever touching the (closed) socket, masking the very
    // failure this test exists to observe.
    try conn.writer.interface.writeAll(
        \\{"id":"1","method":"ping","params":{}}
    );
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();
    _ = try takeLine(&conn.reader.interface);

    // Second request on the same connection: herdr closes after answering a
    // non-subscription request, so either the write or the following read
    // must fail (BrokenPipe/WriteFailed on write, EndOfStream/ReadFailed on
    // read) — both are the expected server-side close, not a client bug.
    const write_failed = blk: {
        conn.writer.interface.writeAll(
            \\{"id":"2","method":"ping","params":{}}
        ) catch break :blk true;
        conn.writer.interface.writeByte('\n') catch break :blk true;
        conn.writer.interface.flush() catch break :blk true;
        break :blk false;
    };

    if (write_failed) {
        // `conn.writer.err` carries the real underlying reason behind the
        // generic `error.WriteFailed`; assert it's actually a closed-peer
        // error, not a vacuous pass on any write failure whatsoever.
        // Observed in practice against the live socket: `SocketUnconnected`.
        const real_err = conn.writer.err orelse return error.UnexpectedResponse;
        try testing.expect(real_err == error.ConnectionResetByPeer or
            real_err == error.SocketUnconnected or
            real_err == error.SocketNotBound);
    } else {
        if (conn.reader.interface.takeDelimiterExclusive('\n')) |_| {
            return error.UnexpectedResponse; // second request should not succeed
        } else |err| {
            try testing.expect(err == error.EndOfStream or err == error.ReadFailed);
        }
    }
}

/// Read one NDJSON line and consume its trailing '\n' (mirrors probe.zig's
/// `takeLine`: `takeDelimiterExclusive` leaves the delimiter in the buffer,
/// which would make the next read on a persistent connection instantly
/// re-find it instead of blocking for new data).
fn takeLine(r: *std.Io.Reader) ![]u8 {
    const line = try r.takeDelimiterInclusive('\n');
    return line[0 .. line.len - 1];
}

test "events.subscribe opens a persistent stream and acks subscription_started" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var conn: Connection = undefined;
    try openLive(&conn, &path_buf);
    defer conn.close();

    const subscribe_json =
        \\{"id":"1","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.updated"},{"type":"layout.updated"}]}}
    ;
    try conn.writer.interface.writeAll(subscribe_json);
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();

    const ack_line = try takeLine(&conn.reader.interface);
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, ack_line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.UnexpectedResponse;
    const rtype = result.object.get("type") orelse return error.UnexpectedResponse;
    try testing.expect(rtype == .string);
    try testing.expectEqualStrings("subscription_started", rtype.string);

    // Whether an `agent_status` shows up within the next few event lines
    // depends on a human interacting with an agent during the capture
    // window — not automatable from here. See the manual script in the QA
    // report for that half of the scenario.
}
