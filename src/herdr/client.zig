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
        req: anytype,
    ) ![]u8 {
        // Serialize request to the writer buffer, then flush.
        try json.Stringify.value(req, .{}, &self.writer.interface);
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

    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        const suffix = "/herdr/herdr.sock";
        if (xdg.len + suffix.len > buf.len) return error.PathTooLong;
        @memcpy(buf[0..xdg.len], xdg);
        @memcpy(buf[xdg.len..][0..suffix.len], suffix);
        return buf[0 .. xdg.len + suffix.len];
    }

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const suffix = "/.config/herdr/herdr.sock";
    if (home.len + suffix.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    return buf[0 .. home.len + suffix.len];
}

/// Default read timeout for `request()`: generous enough for a busy herdr
/// instance, short enough that a genuinely dead server doesn't hang forever.
pub const default_read_timeout_ms: u32 = 15_000;

/// Error codes herdr's protocol-level `{"error":{code,message}}` responses
/// carry. `.unknown` covers any code string herdr adds later that this
/// client doesn't recognize yet — the raw string is still available via
/// `RpcError.message`, so nothing is lost.
pub const RpcErrorCode = enum {
    invalid_request,
    invalid_params,
    agent_blocked,
    agent_not_ready,
    pane_not_found,
    invalid_target,
    ui_busy,
    protocol_mismatch,
    unknown,
};

/// Detail behind `error.HerdrRpc`: herdr answered with a protocol-level
/// error object instead of a result. `message` is gpa-owned — free it with
/// `.deinit(gpa)` once you're done reading it.
pub const RpcError = struct {
    code: RpcErrorCode,
    message: []u8,

    pub fn deinit(self: RpcError, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
    }
};

pub const Response = json.Parsed(json.Value);

var next_id: std.atomic.Value(u64) = .init(1);

/// Times out a blocked read by shutting down the read side of the socket
/// out from under it — `SO_RCVTIMEO` doesn't work here: on Linux a timed-out
/// blocking read returns `EAGAIN`, not `ETIMEDOUT`, and this Io backend's
/// `netReadPosix` treats `EAGAIN` on a blocking socket as a programmer bug
/// and panics (`Threaded.zig:12619`, `errnoBug` at `:14054-14056`).
/// `shutdown(.recv)` is standard POSIX: it makes a concurrently-blocked read
/// on the same socket return `0` (EOF) immediately, which `readVec` already
/// turns into `error.EndOfStream` — no `AGAIN` branch involved.
const Watchdog = struct {
    stream: net.Stream,
    io: Io,
    // `u64`, not `u32`, even though `request()`'s `read_timeout_ms` param is
    // `u32`: `elapsed_ms += slice_ms` below would overflow a `u32` for a
    // timeout near ~49.7 days of milliseconds. Cheap to avoid entirely by
    // widening this one field instead of bounding the loop.
    timeout_ms: u64,
    request_done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        // Sleep in short slices instead of one `timeout_ms`-long sleep, so
        // the happy path (request finishes well under the deadline) doesn't
        // force `wd_thread.join()` to wait out the full timeout.
        const slice_ms: u64 = 10;
        var elapsed_ms: u64 = 0;
        while (elapsed_ms < self.timeout_ms) : (elapsed_ms += slice_ms) {
            if (self.request_done.load(.acquire)) return;
            Io.sleep(self.io, .fromMilliseconds(@intCast(@min(slice_ms, self.timeout_ms - elapsed_ms))), .awake) catch return;
        }
        if (!self.request_done.load(.acquire)) {
            self.fired.store(true, .release);
            self.stream.shutdown(self.io, .recv) catch {};
        }
    }
};

/// One-shot request over `Connection`: opens a fresh connection, sends
/// `method`/`params`, reads one NDJSON response line, and closes — herdr
/// closes after answering any non-subscription method, so a connection per
/// request is the only shape that works here.
///
/// `rpc_err.*` is reset to `null` up front. Invariant: `rpc_err.*` is
/// non-`null` **if and only if** this returns `error.HerdrRpc` — any other
/// return (success or any other error, including `error.OutOfMemory` while
/// building `rpc_err.*` itself) leaves it `null`. So the caller only ever
/// needs `.deinit(gpa)` on it after catching `error.HerdrRpc` specifically.
/// On success the caller owns the returned `Response` and must `.deinit()`
/// it.
pub fn request(
    gpa: std.mem.Allocator,
    io: Io,
    socket_path: []const u8,
    method: []const u8,
    params: anytype,
    read_timeout_ms: u32,
    rpc_err: *?RpcError,
) !Response {
    rpc_err.* = null;

    var conn: Connection = undefined; // must reach its final address before `.open()` — see Connection's doc-comment.
    try conn.open(io, socket_path);
    defer conn.close();

    var id_buf: [20]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d}", .{next_id.fetchAdd(1, .monotonic)});

    var wd: Watchdog = .{ .stream = conn.stream, .io = io, .timeout_ms = read_timeout_ms };
    const wd_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&wd});

    const send_result = conn.sendRequest(.{ .id = id, .method = method, .params = params });
    wd.request_done.store(true, .release);
    wd_thread.join();

    const line = send_result catch |err| {
        if (wd.fired.load(.acquire)) return error.Timeout;
        return err;
    };

    const parsed = try json.parseFromSlice(json.Value, gpa, line, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.UnexpectedResponse;

    if (parsed.value.object.get("error")) |err_obj| {
        if (err_obj != .object) return error.UnexpectedResponse;
        const code_val = err_obj.object.get("code") orelse return error.UnexpectedResponse;
        if (code_val != .string) return error.UnexpectedResponse;
        const msg_val = err_obj.object.get("message") orelse return error.UnexpectedResponse;
        if (msg_val != .string) return error.UnexpectedResponse;

        // `gpa.dupe` must be evaluated *before* the struct literal is written
        // into `rpc_err.*` — Zig's result-location semantics write `.code`
        // directly into `rpc_err.*` first, so if this `try` failed inline in
        // the literal, `rpc_err.*` would be left non-null with `.message`
        // pointing at uninitialized memory (the caller's `.deinit(gpa)` on
        // that garbage pointer is heap corruption, not a catchable error).
        const message = try gpa.dupe(u8, msg_val.string);
        rpc_err.* = .{
            .code = std.meta.stringToEnum(RpcErrorCode, code_val.string) orelse .unknown,
            .message = message,
        };
        return error.HerdrRpc; // `errdefer` above frees `parsed` on this path.
    }

    return parsed;
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

test "request: ping against herdr real returns pong (gated HERDR_ENV=1)" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try liveSocketPathOrSkip(&path_buf);

    var rpc_err: ?RpcError = null;
    const resp = request(testing.allocator, testing.io, path, "ping", .{}, default_read_timeout_ms, &rpc_err) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest; // no live socket here
        return err;
    };
    defer resp.deinit();

    try testing.expect(rpc_err == null);
    const result = resp.value.object.get("result") orelse return error.UnexpectedResponse;
    const rtype = result.object.get("type") orelse return error.UnexpectedResponse;
    try testing.expect(rtype == .string);
    try testing.expectEqualStrings("pong", rtype.string);
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

// ---------------------------------------------------------------------------
// Tests for `request()` and the `XDG_CONFIG_HOME` step of `resolveSocketPath`
// — Gherkin scenarios from roadmap/designs/8-cliente-rpc.md.
//
// These use a `FakeServer` (a real Unix socket listener on a thread) instead
// of the live herdr socket, so they run everywhere `zig build test` runs,
// not just inside a herdr session.
// ---------------------------------------------------------------------------

var fake_server_next_id: std.atomic.Value(u32) = .init(0);

const FakeServerScript = enum {
    /// Responds `{"result":{"type":"pong"}}` in a single write.
    ping_ok,
    /// Same response, split across two writes with a short sleep between —
    /// covers the "assembles across fragments" scenario.
    ping_split,
    /// Responds a protocol-level error object.
    protocol_error,
    /// Drains the request, then closes without writing anything.
    close_no_response,
    /// Drains the request, then sleeps well past the client's injected
    /// timeout without ever responding.
    hang,
    /// Responds a top-level JSON array — not the `{"result"|"error":...}`
    /// object shape `request()` expects.
    top_level_array,
    /// Responds `{"error":"boom"}` — `error` present but not an object.
    error_not_object,
    /// Responds a protocol error object missing `message`.
    protocol_error_no_message,
};

/// Set by `fakeServerThread` to whatever request line it drained — lets
/// tests assert on what the client actually sent over the wire. Safe as a
/// package-level `var`: `zig build test` runs tests sequentially, and each
/// test's `FakeServer` thread is joined before the next test starts.
var last_received_line_buf: [256]u8 = undefined;
var last_received_line_len: usize = 0;

fn fakeServerThread(server: *net.Server, io: Io, script: FakeServerScript) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);

    // Drain the request line first so the client's write never races the
    // server closing the socket out from under it.
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    if (reader.interface.takeDelimiterExclusive('\n') catch null) |line| {
        last_received_line_len = @min(line.len, last_received_line_buf.len);
        @memcpy(last_received_line_buf[0..last_received_line_len], line[0..last_received_line_len]);
    }

    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    switch (script) {
        .ping_ok => {
            writer.interface.writeAll("{\"result\":{\"type\":\"pong\"}}\n") catch return;
            writer.interface.flush() catch return;
        },
        .ping_split => {
            writer.interface.writeAll("{\"result\":{\"type\"") catch return;
            writer.interface.flush() catch return;
            io.sleep(.fromMilliseconds(20), .awake) catch return;
            writer.interface.writeAll(":\"pong\"}}\n") catch return;
            writer.interface.flush() catch return;
        },
        .protocol_error => {
            writer.interface.writeAll(
                "{\"error\":{\"code\":\"invalid_params\",\"message\":\"falta X\"}}\n",
            ) catch return;
            writer.interface.flush() catch return;
        },
        .close_no_response => {},
        .hang => {
            io.sleep(.fromMilliseconds(300), .awake) catch {};
        },
        .top_level_array => {
            writer.interface.writeAll("[1,2,3]\n") catch return;
            writer.interface.flush() catch return;
        },
        .error_not_object => {
            writer.interface.writeAll("{\"error\":\"boom\"}\n") catch return;
            writer.interface.flush() catch return;
        },
        .protocol_error_no_message => {
            writer.interface.writeAll("{\"error\":{\"code\":\"invalid_params\"}}\n") catch return;
            writer.interface.flush() catch return;
        },
    }
}

/// Starts a `FakeServer` on a unique `/tmp` socket path and spawns the
/// accept/respond thread. The listener (`server`) is an out-parameter —
/// same address contract as `Connection.open`: it must already live at its
/// final address before this runs, since the spawned thread captures a
/// pointer to it. Callers must `defer thread.join()` before `defer
/// server.deinit(io)` (LIFO: join first, then deinit) so the thread never
/// touches `server` after it's torn down.
fn startFakeServer(
    server: *net.Server,
    io: Io,
    script: FakeServerScript,
    path_buf: *[64]u8,
) !struct { path: []const u8, thread: std.Thread } {
    const path = try std.fmt.bufPrint(
        path_buf,
        "/tmp/kelpie-herdr-fake-{d}-{d}.sock",
        .{ std.posix.system.getpid(), fake_server_next_id.fetchAdd(1, .monotonic) },
    );
    const addr = try net.UnixAddress.init(path);
    server.* = try addr.listen(io, .{});
    const thread = try std.Thread.spawn(.{}, fakeServerThread, .{ server, io, script });
    return .{ .path = path, .thread = thread };
}

/// Test-only: mirrors `request()`'s connection setup (`var conn: Connection
/// = undefined` local, `.open()`, never copied afterwards) so the memory
/// guard `openLive`'s test already checks for that call-site also covers
/// `request()`'s own `conn` — without exposing it from the public function.
fn openForRequestGuardTest(io: Io, socket_path: []const u8) !void {
    var conn: Connection = undefined;
    try conn.open(io, socket_path);
    defer conn.close();
    try testing.expectEqual(@intFromPtr(&conn.read_buf), @intFromPtr(conn.reader.interface.buffer.ptr));
}

test "request: conn's reader buffer never moves off conn's address" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .close_no_response, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    try openForRequestGuardTest(testing.io, started.path);
}

test "request: ping against a FakeServer that answers in one write" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .ping_ok, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const resp = try request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    defer resp.deinit();

    try testing.expect(rpc_err == null);
    const result = resp.value.object.get("result") orelse return error.UnexpectedResponse;
    const rtype = result.object.get("type") orelse return error.UnexpectedResponse;
    try testing.expectEqualStrings("pong", rtype.string);
}

test "request: happy path doesn't block for the full read_timeout_ms" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .ping_ok, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const start = std.Io.Timestamp.now(testing.io, .awake);
    const resp = try request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    defer resp.deinit();
    const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));

    // Regression guard for the watchdog blocking the happy path for the
    // full 15s timeout: this must finish in well under 1s of wall time.
    try testing.expect(elapsed.nanoseconds < std.time.ns_per_s);
}

test "request: top-level non-object response is error.UnexpectedResponse, no panic" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .top_level_array, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const result = request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    try testing.expectError(error.UnexpectedResponse, result);
}

test "request: non-object error field is error.UnexpectedResponse, no panic" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .error_not_object, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const result = request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    try testing.expectError(error.UnexpectedResponse, result);
}

test "request: protocol error missing message field doesn't leak the parsed JSON" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .protocol_error_no_message, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const result = request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    try testing.expectError(error.UnexpectedResponse, result);
    try testing.expect(rpc_err == null);
}

test "request: OutOfMemory while building rpc_err never leaves rpc_err non-null" {
    // Sweeps `FailingAllocator.fail_index` across every allocation `request()`
    // makes on the `.protocol_error` path (json parse tree + the `code`/
    // `message` dupe) — regression for the bug where `rpc_err.*` got a valid
    // `.code` written before the `.message` dupe's `try` could fail, leaving
    // a garbage `.message` pointer behind for the caller to `.deinit()`.
    var fail_index: usize = 0;
    while (fail_index < 30) : (fail_index += 1) {
        var path_buf: [64]u8 = undefined;
        var server: net.Server = undefined;
        const started = try startFakeServer(&server, testing.io, .protocol_error, &path_buf);
        defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
        defer server.deinit(testing.io);
        defer started.thread.join();

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var rpc_err: ?RpcError = null;
        const result = request(failing.allocator(), testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);

        if (result) |resp| {
            resp.deinit();
            try testing.expect(rpc_err == null);
        } else |err| switch (err) {
            error.HerdrRpc => (rpc_err orelse return error.UnexpectedResponse).deinit(testing.allocator),
            error.OutOfMemory => try testing.expect(rpc_err == null),
            else => return err,
        }
    }
}

test "request: response split across two writes still assembles" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .ping_split, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const resp = try request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    defer resp.deinit();

    const result = resp.value.object.get("result") orelse return error.UnexpectedResponse;
    const rtype = result.object.get("type") orelse return error.UnexpectedResponse;
    try testing.expectEqualStrings("pong", rtype.string);
}

test "request: protocol error maps to error.HerdrRpc with a typed code" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .protocol_error, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const result = request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    try testing.expectError(error.HerdrRpc, result);

    const err = rpc_err orelse return error.UnexpectedResponse;
    defer err.deinit(testing.allocator);
    try testing.expectEqual(RpcErrorCode.invalid_params, err.code);
    try testing.expect(std.mem.indexOf(u8, err.message, "falta X") != null);
}

test "request: server closes without responding surfaces error.EndOfStream" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .close_no_response, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const result = request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    try testing.expectError(error.EndOfStream, result);
}

test "request: no response within the injected timeout surfaces error.Timeout" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .hang, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const result = request(testing.allocator, testing.io, started.path, "ping", .{}, 50, &rpc_err);
    try testing.expectError(error.Timeout, result);
}

test "request: emits the id field as a JSON string, never a bare number" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const started = try startFakeServer(&server, testing.io, .ping_ok, &path_buf);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, started.path) catch {};
    defer server.deinit(testing.io);
    defer started.thread.join();

    var rpc_err: ?RpcError = null;
    const resp = try request(testing.allocator, testing.io, started.path, "ping", .{}, default_read_timeout_ms, &rpc_err);
    defer resp.deinit();

    // `fakeServerThread` copies the raw request line it drained into
    // `last_received_line_buf` before responding — inspect what `request()`
    // actually put on the wire.
    const sent = last_received_line_buf[0..last_received_line_len];
    try testing.expect(std.mem.indexOf(u8, sent, "\"id\":\"") != null);
}

test "resolveSocketPath: HERDR_SOCKET_PATH wins over everything" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HERDR_SOCKET_PATH", "/custom/herdr.sock");
    try env.put("XDG_CONFIG_HOME", "/xdg");
    try env.put("HOME", "/home/x");

    const path = try resolveSocketPath(env, &buf);
    try testing.expectEqualStrings("/custom/herdr.sock", path);
}

test "resolveSocketPath: XDG_CONFIG_HOME is the second step" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/xdg");
    try env.put("HOME", "/home/x");

    const path = try resolveSocketPath(env, &buf);
    try testing.expectEqualStrings("/xdg/herdr/herdr.sock", path);
}

test "resolveSocketPath: HOME is the fallback" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/x");

    const path = try resolveSocketPath(env, &buf);
    try testing.expectEqualStrings("/home/x/.config/herdr/herdr.sock", path);
}
