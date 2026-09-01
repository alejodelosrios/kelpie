const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const json = std.json;

const client = @import("client.zig");
const types = @import("types.zig");

/// Callback delivery seam: `EventsClient`'s reader thread never calls
/// `on_event`/`on_resynced` directly — it always goes through
/// `Dispatcher.invoke`. Production wraps `glib.MainContext.invoke`
/// (lives in `src/ui/herdr_link.zig`); that binding packs two pointers
/// (`task` + `task_ctx`) into the single `user_data` GLib accepts, which
/// requires a heap allocation that can fail — hence `!void`.
pub const Dispatcher = struct {
    ptr: *anyopaque,
    invokeFn: *const fn (ptr: *anyopaque, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) anyerror!void,

    pub fn invoke(self: Dispatcher, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) !void {
        return self.invokeFn(self.ptr, task, task_ctx);
    }
};

/// Backoff-delay seam: production sleeps for real (`Io.sleep`, via
/// `ioSleeper`); tests inject one that records the requested `ms` and
/// returns immediately, so the `1,2,4,8,16,30,30…` sequence is verifiable
/// without a slow test.
pub const Sleeper = struct {
    ptr: *anyopaque,
    sleepFn: *const fn (ptr: *anyopaque, ms: u32) void,

    pub fn sleep(self: Sleeper, ms: u32) void {
        self.sleepFn(self.ptr, ms);
    }
};

/// Production `Sleeper`: backs `.sleep()` with the real `Io.sleep`, sliced
/// into 10ms steps checking `stopping` (same pattern as `client.zig:141-149`'s
/// `Watchdog.run`) so a `stop()` call during a long backoff wait returns
/// almost immediately instead of blocking for the full delay. Caller owns
/// the storage (must outlive the `EventsClient` it's wired into) and must
/// point `stopping` at that same `EventsClient`'s `.stopping` field.
pub const IoSleeper = struct {
    io: Io,
    stopping: *const std.atomic.Value(bool),

    pub fn sleeper(self: *IoSleeper) Sleeper {
        return .{ .ptr = self, .sleepFn = sleepImpl };
    }

    fn sleepImpl(ptr: *anyopaque, ms: u32) void {
        const self: *IoSleeper = @ptrCast(@alignCast(ptr));
        const slice_ms: u32 = 10;
        var elapsed: u32 = 0;
        while (elapsed < ms) : (elapsed += slice_ms) {
            if (self.stopping.load(.acquire)) return;
            Io.sleep(self.io, .fromMilliseconds(@min(slice_ms, ms - elapsed)), .awake) catch return;
        }
    }
};

/// Subscription-type strings sent in `events.subscribe`'s
/// `params.subscriptions`. The 24 event types whose schema
/// `Subscription.oneOf` variant requires only `type` (verified against
/// testdata/herdr-api.schema.json). Excluded on purpose: `pane.output_matched`,
/// `pane.agent_status_changed`, `pane.scroll_changed` — the only three
/// variants with an extra required field; agent-status changes already
/// arrive globally via `pane.updated`.
const subscription_types = [_][]const u8{
    "workspace.created", "workspace.updated",   "workspace.metadata_updated",
    "workspace.renamed", "workspace.moved",     "workspace.reordered",
    "workspace.closed",  "workspace.focused",   "worktree.created",
    "worktree.opened",   "worktree.removed",    "tab.created",
    "tab.closed",        "tab.focused",         "tab.renamed",
    "tab.moved",         "pane.created",        "pane.closed",
    "pane.updated",      "pane.focused",        "pane.moved",
    "pane.exited",       "pane.agent_detected", "layout.updated",
};

const Subscription = struct { type: []const u8 };

const backoff_start_ms: u32 = 1_000;
const backoff_max_ms: u32 = 30_000;

pub const EventsClient = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Caller-owned: must outlive the reader thread, which starts with
    /// `start()` and only stops once `stop()` returns.
    socket_path: []const u8,
    dispatcher: Dispatcher,
    sleeper: Sleeper,
    on_event: *const fn (ctx: *anyopaque, envelope: types.EventEnvelope) void,
    on_resynced: *const fn (ctx: *anyopaque, snapshot: types.SessionSnapshot) void,
    callback_ctx: *anyopaque,

    stopping: std.atomic.Value(bool) = .init(false),
    /// Fd of the connection currently open for reading, or `-1` — not the
    /// whole `Connection` struct, so `stop()` can read it without racing the
    /// reader thread's writes to `Connection`'s other fields (`Stream.shutdown`
    /// only touches `.socket.handle`, never `.address` — see
    /// `/usr/lib/zig/std/Io/net.zig:1252-1254`).
    active_fd: std.atomic.Value(net.Socket.Handle) = .init(-1),
    thread: ?std.Thread = null,

    pub fn start(self: *EventsClient) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Clean shutdown: marks `stopping`, unblocks a read in progress with
    /// `shutdown(.recv)` on the active fd (same mechanism as
    /// `client.zig:130-156`'s `Watchdog`), then joins the reader thread.
    pub fn stop(self: *EventsClient) void {
        self.stopping.store(true, .release);
        const fd = self.active_fd.load(.acquire);
        if (fd != -1) {
            const tmp: net.Stream = .{ .socket = .{ .handle = fd, .address = undefined } };
            tmp.shutdown(self.io, .recv) catch {};
        }
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn run(self: *EventsClient) void {
        var backoff_ms: u32 = backoff_start_ms;
        while (!self.stopping.load(.acquire)) {
            self.runOnce(&backoff_ms) catch {};
            if (self.stopping.load(.acquire)) return;
            self.sleeper.sleep(backoff_ms);
            backoff_ms = @min(backoff_ms * 2, backoff_max_ms);
        }
    }

    /// One connect-subscribe-read cycle. Returns (or errors) once the
    /// connection ends, having always closed it first.
    fn runOnce(self: *EventsClient, backoff_ms: *u32) !void {
        var conn: client.Connection = undefined;
        try conn.open(self.io, self.socket_path);
        defer conn.close();
        self.active_fd.store(conn.stream.socket.handle, .release);
        defer self.active_fd.store(-1, .release);
        // `stop()` may have run in the open()..store() window above, missed
        // seeing a valid fd, and skipped the shutdown that would otherwise
        // unblock the read loop below — catch that here before it can hang.
        if (self.stopping.load(.acquire)) return;

        try sendSubscribe(&conn);
        const ack_line = try takeLine(&conn.reader.interface);
        try checkAck(self.gpa, ack_line);

        // Ack received: reset the backoff sequence regardless of what
        // happens for the rest of this cycle.
        backoff_ms.* = backoff_start_ms;

        self.resync();

        while (true) {
            const line = try takeLine(&conn.reader.interface);
            // A single malformed/unrecognized event must not tear down an
            // otherwise-healthy connection — only transport errors from
            // `takeLine` above should trigger a reconnect.
            self.deliverEvent(line) catch {};
        }
    }

    fn resync(self: *EventsClient) void {
        var rpc_err: ?client.RpcError = null;
        const resp = client.request(self.gpa, self.io, self.socket_path, "session.snapshot", .{}, client.default_read_timeout_ms, &rpc_err) catch |err| {
            if (err == error.HerdrRpc) rpc_err.?.deinit(self.gpa);
            return;
        };
        defer resp.deinit();
        if (resp.value != .object) return;

        const result = resp.value.object.get("result") orelse return;
        if (result != .object) return;
        const snapshot_value = result.object.get("snapshot") orelse return;

        const parsed_snapshot = json.parseFromValue(types.SessionSnapshot, self.gpa, snapshot_value, .{ .ignore_unknown_fields = true }) catch return;
        errdefer parsed_snapshot.deinit();

        // Heap-allocated, not a stack local: `Dispatcher.invoke` isn't
        // guaranteed synchronous (production wraps `glib.MainContext.invoke`,
        // which can queue and return before the task runs) — the trampoline
        // frees both the parsed snapshot and this ctx once it's actually
        // done with them.
        const ctx = self.gpa.create(ResyncCtx) catch {
            parsed_snapshot.deinit();
            return;
        };
        ctx.* = .{ .client = self, .parsed = parsed_snapshot };
        self.dispatcher.invoke(resyncTrampoline, ctx) catch {
            parsed_snapshot.deinit();
            self.gpa.destroy(ctx);
            return;
        };
    }

    fn deliverEvent(self: *EventsClient, line: []const u8) !void {
        const parsed = try json.parseFromSlice(types.EventEnvelope, self.gpa, line, .{ .ignore_unknown_fields = true });
        errdefer parsed.deinit();

        // Same heap-ownership-transfer reasoning as `resync()` above.
        const ctx = try self.gpa.create(EventCtx);
        ctx.* = .{ .client = self, .parsed = parsed };
        self.dispatcher.invoke(eventTrampoline, ctx) catch {
            // errdefer frees `parsed`; we only need to destroy the ctx.
            self.gpa.destroy(ctx);
            return error.OutOfMemory;
        };
    }
};

const EventCtx = struct { client: *EventsClient, parsed: json.Parsed(types.EventEnvelope) };
fn eventTrampoline(ctx: *anyopaque) void {
    const c: *EventCtx = @ptrCast(@alignCast(ctx));
    c.client.on_event(c.client.callback_ctx, c.parsed.value);
    c.parsed.deinit();
    c.client.gpa.destroy(c);
}

const ResyncCtx = struct { client: *EventsClient, parsed: json.Parsed(types.SessionSnapshot) };
fn resyncTrampoline(ctx: *anyopaque) void {
    const c: *ResyncCtx = @ptrCast(@alignCast(ctx));
    c.client.on_resynced(c.client.callback_ctx, c.parsed.value);
    c.parsed.deinit();
    c.client.gpa.destroy(c);
}

fn sendSubscribe(conn: *client.Connection) !void {
    var subs: [subscription_types.len]Subscription = undefined;
    for (subscription_types, 0..) |t, i| subs[i] = .{ .type = t };

    try json.Stringify.value(
        .{ .id = "1", .method = "events.subscribe", .params = .{ .subscriptions = subs } },
        .{},
        &conn.writer.interface,
    );
    try conn.writer.interface.writeByte('\n');
    try conn.writer.interface.flush();
}

fn checkAck(gpa: std.mem.Allocator, line: []const u8) !void {
    const parsed = try json.parseFromSlice(json.Value, gpa, line, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != .object) return error.UnexpectedResponse;
    const result = parsed.value.object.get("result") orelse return error.UnexpectedResponse;
    if (result != .object) return error.UnexpectedResponse;
    const rtype = result.object.get("type") orelse return error.UnexpectedResponse;
    if (rtype != .string) return error.UnexpectedResponse;
    if (!std.mem.eql(u8, rtype.string, "subscription_started")) return error.UnexpectedResponse;
}

/// Read one NDJSON line and consume its trailing '\n' — same pattern as
/// `client.zig:465-472`'s private `takeLine`, replicated here because
/// `Connection.sendRequest`/`request()` are one-shot and don't fit a
/// persistent, kept-open connection.
fn takeLine(r: *std.Io.Reader) ![]u8 {
    const line = try r.takeDelimiterInclusive('\n');
    return line[0 .. line.len - 1];
}

// ---------------------------------------------------------------------------
// Tests — Gherkin scenarios from roadmap/designs/10-eventos-reconexion.md
// ---------------------------------------------------------------------------

const testing = std.testing;

var fake_server_next_id: std.atomic.Value(u32) = .init(0);

fn startFakeServer(server: *net.Server, io: Io, path_buf: *[64]u8) ![]const u8 {
    const path = try std.fmt.bufPrint(
        path_buf,
        "/tmp/kelpie-events-fake-{d}-{d}.sock",
        .{ std.posix.system.getpid(), fake_server_next_id.fetchAdd(1, .monotonic) },
    );
    const addr = try net.UnixAddress.init(path);
    server.* = try addr.listen(io, .{});
    return path;
}

const snapshot_json = "{\"result\":{\"snapshot\":{\"version\":\"1\",\"protocol\":20,\"workspaces\":[],\"tabs\":[],\"panes\":[],\"layouts\":[],\"agents\":[]}}}\n";

/// Drains one NDJSON request line off `stream` — best effort, errors ignored,
/// mirroring how a fake test server doesn't need to validate the request.
fn drainRequestLine(stream: net.Stream, io: Io) void {
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    _ = reader.interface.takeDelimiterInclusive('\n') catch {};
}

fn respond(stream: net.Stream, io: Io, body: []const u8) void {
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(body) catch return;
    writer.interface.flush() catch return;
}

/// One full connect cycle a FakeServer can play out for `EventsClient`:
/// accept the subscribe connection, optionally ack it, optionally serve a
/// resync connection, then optionally write event lines before closing.
const CycleScript = struct {
    ack: bool = true,
    resync: bool = true,
    events: []const []const u8 = &.{},
};

fn fakeEventsServerThread(server: *net.Server, io: Io, scripts: []const CycleScript) void {
    for (scripts) |script| {
        const stream1 = server.accept(io) catch return;
        drainRequestLine(stream1, io);

        if (script.ack) {
            respond(stream1, io, "{\"result\":{\"type\":\"subscription_started\"}}\n");
        } else {
            stream1.close(io);
            continue;
        }

        if (script.resync) {
            const stream2 = server.accept(io) catch {
                stream1.close(io);
                return;
            };
            drainRequestLine(stream2, io);
            respond(stream2, io, snapshot_json);
            stream2.close(io);
        }

        for (script.events) |line| {
            var write_buf: [4096]u8 = undefined;
            var writer = stream1.writer(io, &write_buf);
            writer.interface.writeAll(line) catch break;
            writer.interface.writeByte('\n') catch break;
            writer.interface.flush() catch break;
        }
        stream1.close(io);
    }
}

/// `Dispatcher` test double: records how many times it ran a task, and
/// whether any of those tasks ran on a thread other than whichever thread
/// called `invoke` (the reader thread, by `EventsClient`'s contract) — the
/// mechanical proxy for "callbacks never fire directly from the reader
/// thread" from the design's Gherkin scenario.
const ThreadIdDispatcher = struct {
    saw_different_thread: std.atomic.Value(bool) = .init(false),
    invoke_count: std.atomic.Value(u32) = .init(0),

    fn dispatcher(self: *@This()) Dispatcher {
        return .{ .ptr = self, .invokeFn = invokeImpl };
    }

    const Args = struct {
        self: *ThreadIdDispatcher,
        caller_id: std.Thread.Id,
        task: *const fn (ctx: *anyopaque) void,
        task_ctx: *anyopaque,
    };

    fn invokeImpl(ptr: *anyopaque, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const args = Args{ .self = self, .caller_id = std.Thread.getCurrentId(), .task = task, .task_ctx = task_ctx };
        const t = try std.Thread.spawn(.{}, runTask, .{args});
        t.join();
    }

    fn runTask(args: Args) void {
        if (std.Thread.getCurrentId() != args.caller_id) {
            args.self.saw_different_thread.store(true, .release);
        }
        _ = args.self.invoke_count.fetchAdd(1, .monotonic);
        args.task(args.task_ctx);
    }
};

/// `Dispatcher` test double that queues tasks instead of running them inline
/// — mimics a real `glib.MainContext.invoke` call from a non-owning thread,
/// which enqueues and returns immediately rather than running synchronously.
/// Exists to catch the UAF a synchronous-only dispatcher test double
/// (`ThreadIdDispatcher` above) can't: if `EventsClient` freed its ctx/parsed
/// JSON before the task actually ran, `drain()` would read freed memory.
const QueueingDispatcher = struct {
    const QueuedTask = struct { task: *const fn (ctx: *anyopaque) void, ctx: *anyopaque };

    queue: [64]QueuedTask = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn dispatcher(self: *@This()) Dispatcher {
        return .{ .ptr = self, .invokeFn = invokeImpl };
    }

    fn invokeImpl(ptr: *anyopaque, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const i = self.len.fetchAdd(1, .acq_rel);
        if (i < self.queue.len) self.queue[i] = .{ .task = task, .ctx = task_ctx };
    }

    /// Runs every queued task, in order. Call only after the producing
    /// `EventsClient` has stopped reading more than `queue.len` events.
    fn drain(self: *@This()) void {
        const n = @min(self.len.load(.acquire), self.queue.len);
        for (self.queue[0..n]) |qt| qt.task(qt.ctx);
    }
};

/// `Sleeper` test double: records requested `ms` without sleeping, so
/// backoff-sequence tests run instantly. Fixed-capacity + atomic index
/// instead of a mutex-guarded list — plenty for these short test runs and
/// avoids `std.Io.Mutex`'s `Io`-threaded lock/unlock in a plain test double.
const RecordingSleeper = struct {
    recorded: [32]u32 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn sleeper(self: *@This()) Sleeper {
        return .{ .ptr = self, .sleepFn = sleepImpl };
    }

    fn sleepImpl(ptr: *anyopaque, ms: u32) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const i = self.len.fetchAdd(1, .acq_rel);
        if (i < self.recorded.len) self.recorded[i] = ms;
    }

    fn count(self: *@This()) usize {
        return @min(self.len.load(.acquire), self.recorded.len);
    }
};

/// Callback test double: records every `on_event`/`on_resynced` delivery.
const RecordingCallbacks = struct {
    events: [32]types.EventKind = undefined,
    events_len: std.atomic.Value(usize) = .init(0),
    resync_count: std.atomic.Value(u32) = .init(0),

    fn onEvent(ctx: *anyopaque, envelope: types.EventEnvelope) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const i = self.events_len.fetchAdd(1, .acq_rel);
        if (i < self.events.len) self.events[i] = envelope.event;
    }

    fn onResynced(ctx: *anyopaque, _: types.SessionSnapshot) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        _ = self.resync_count.fetchAdd(1, .monotonic);
    }

    fn count(self: *@This()) usize {
        return @min(self.events_len.load(.acquire), self.events.len);
    }
};

/// Busy-poll a condition with real (short) sleeps — used only to wait for a
/// background `EventsClient` thread to make progress before asserting.
fn waitUntil(io: Io, comptime T: type, ctx: *T, comptime check: fn (*T) bool, max_ms: u32) void {
    var waited: u32 = 0;
    while (!check(ctx) and waited < max_ms) : (waited += 5) {
        Io.sleep(io, .fromMilliseconds(5), .awake) catch return;
    }
}

test "FakeServer emits ack + 3 events and closes: events deliver in order via dispatcher.invoke, then resync fires" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const path = try startFakeServer(&server, testing.io, &path_buf);
    defer Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    const scripts = [_]CycleScript{
        .{ .events = &.{
            "{\"event\":\"pane_created\",\"data\":{}}",
            "{\"event\":\"pane_updated\",\"data\":{}}",
            "{\"event\":\"pane_closed\",\"data\":{}}",
        } },
    };
    const server_thread = try std.Thread.spawn(.{}, fakeEventsServerThread, .{ &server, testing.io, &scripts });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var callbacks = RecordingCallbacks{};
    var thread_id_dispatcher = ThreadIdDispatcher{};
    var no_sleep = RecordingSleeper{};

    const socket_path = try testing.allocator.dupe(u8, path);
    defer testing.allocator.free(socket_path);

    var events_client = EventsClient{
        .gpa = testing.allocator,
        .io = testing.io,
        .socket_path = socket_path,
        .dispatcher = thread_id_dispatcher.dispatcher(),
        .sleeper = no_sleep.sleeper(),
        .on_event = RecordingCallbacks.onEvent,
        .on_resynced = RecordingCallbacks.onResynced,
        .callback_ctx = &callbacks,
    };
    try events_client.start();

    const Check = struct {
        fn done(cb: *RecordingCallbacks) bool {
            return cb.count() >= 3 and cb.resync_count.load(.acquire) >= 1;
        }
    };
    waitUntil(testing.io, RecordingCallbacks, &callbacks, Check.done, 2000);
    events_client.stop();

    try testing.expectEqual(@as(usize, 3), callbacks.count());
    try testing.expectEqual(types.EventKind.pane_created, callbacks.events[0]);
    try testing.expectEqual(types.EventKind.pane_updated, callbacks.events[1]);
    try testing.expectEqual(types.EventKind.pane_closed, callbacks.events[2]);
    try testing.expect(callbacks.resync_count.load(.acquire) >= 1);
    try testing.expect(thread_id_dispatcher.invoke_count.load(.acquire) >= 4); // 3 events + 1 resync
    try testing.expect(thread_id_dispatcher.saw_different_thread.load(.acquire));
}

test "reconnect backoff: 1000, 2000, then resets to 1000 after a fresh ack" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const path = try startFakeServer(&server, testing.io, &path_buf);
    defer Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    // Cycle 1: ack + resync, then close with no events -> failure after reset (sleep 1000).
    // Cycle 2: no ack at all -> failure without a reset (sleep 2000, since backoff doubled after cycle 1).
    // Cycle 3: ack + resync, then close -> failure right after a fresh reset (sleep 1000 again, not 4000).
    const scripts = [_]CycleScript{
        .{ .ack = true, .resync = true, .events = &.{} },
        .{ .ack = false },
        .{ .ack = true, .resync = true, .events = &.{} },
    };
    const server_thread = try std.Thread.spawn(.{}, fakeEventsServerThread, .{ &server, testing.io, &scripts });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var callbacks = RecordingCallbacks{};
    var thread_id_dispatcher = ThreadIdDispatcher{};
    var recording_sleeper = RecordingSleeper{};

    const socket_path = try testing.allocator.dupe(u8, path);
    defer testing.allocator.free(socket_path);

    var events_client = EventsClient{
        .gpa = testing.allocator,
        .io = testing.io,
        .socket_path = socket_path,
        .dispatcher = thread_id_dispatcher.dispatcher(),
        .sleeper = recording_sleeper.sleeper(),
        .on_event = RecordingCallbacks.onEvent,
        .on_resynced = RecordingCallbacks.onResynced,
        .callback_ctx = &callbacks,
    };
    try events_client.start();

    const Check = struct {
        fn done(s: *RecordingSleeper) bool {
            return s.count() >= 3;
        }
    };
    waitUntil(testing.io, RecordingSleeper, &recording_sleeper, Check.done, 2000);
    events_client.stop();

    try testing.expect(recording_sleeper.count() >= 3);
    try testing.expectEqual(@as(u32, 1000), recording_sleeper.recorded[0]);
    try testing.expectEqual(@as(u32, 2000), recording_sleeper.recorded[1]);
    try testing.expectEqual(@as(u32, 1000), recording_sleeper.recorded[2]);
}

test "stop() unblocks a connection that never responds, and the thread joins cleanly" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const path = try startFakeServer(&server, testing.io, &path_buf);
    defer Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    // Server accepts and then just hangs — never acks, never closes.
    const HangServer = struct {
        fn run(srv: *net.Server, io: Io) void {
            const stream = srv.accept(io) catch return;
            defer stream.close(io);
            io.sleep(.fromMilliseconds(5000), .awake) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, HangServer.run, .{ &server, testing.io });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var callbacks = RecordingCallbacks{};
    var thread_id_dispatcher = ThreadIdDispatcher{};
    var no_sleep = RecordingSleeper{};

    const socket_path = try testing.allocator.dupe(u8, path);
    defer testing.allocator.free(socket_path);

    var events_client = EventsClient{
        .gpa = testing.allocator,
        .io = testing.io,
        .socket_path = socket_path,
        .dispatcher = thread_id_dispatcher.dispatcher(),
        .sleeper = no_sleep.sleeper(),
        .on_event = RecordingCallbacks.onEvent,
        .on_resynced = RecordingCallbacks.onResynced,
        .callback_ctx = &callbacks,
    };
    try events_client.start();

    // Give the reader thread a moment to actually be blocked in the read.
    Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
    events_client.stop(); // must return — regression guard against a hang.
}

test "queueing dispatcher: ctx and parsed JSON survive until the task actually runs, later, without leaking" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const path = try startFakeServer(&server, testing.io, &path_buf);
    defer Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    const scripts = [_]CycleScript{
        .{ .events = &.{
            "{\"event\":\"pane_created\",\"data\":{}}",
            "{\"event\":\"pane_updated\",\"data\":{}}",
        } },
    };
    const server_thread = try std.Thread.spawn(.{}, fakeEventsServerThread, .{ &server, testing.io, &scripts });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var callbacks = RecordingCallbacks{};
    var queueing_dispatcher = QueueingDispatcher{};
    var no_sleep = RecordingSleeper{};

    const socket_path = try testing.allocator.dupe(u8, path);
    defer testing.allocator.free(socket_path);

    var events_client = EventsClient{
        .gpa = testing.allocator,
        .io = testing.io,
        .socket_path = socket_path,
        .dispatcher = queueing_dispatcher.dispatcher(),
        .sleeper = no_sleep.sleeper(),
        .on_event = RecordingCallbacks.onEvent,
        .on_resynced = RecordingCallbacks.onResynced,
        .callback_ctx = &callbacks,
    };
    try events_client.start();

    const Check = struct {
        fn done(qd: *QueueingDispatcher) bool {
            return qd.len.load(.acquire) >= 3; // 1 resync + 2 events queued
        }
    };
    waitUntil(testing.io, QueueingDispatcher, &queueing_dispatcher, Check.done, 2000);
    events_client.stop();

    // Nothing has executed yet — the reader thread (and every frame that
    // built a ctx/`Parsed` for `invoke`) is long gone, but the heap-owned
    // ctx/JSON the queue is holding onto must still be valid to read here.
    try testing.expectEqual(@as(usize, 0), callbacks.count());

    queueing_dispatcher.drain();

    try testing.expect(callbacks.count() >= 2);
    try testing.expect(callbacks.resync_count.load(.acquire) >= 1);
    // `testing.allocator` fails the test on any leak — each drained task
    // must free its own ctx/`Parsed`, no more and no less.
}

test "stop() during a backoff sleep returns fast, not after the full delay" {
    var path_buf: [64]u8 = undefined;
    var server: net.Server = undefined;
    const path = try startFakeServer(&server, testing.io, &path_buf);
    defer Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    // Server accepts and immediately closes without acking — every cycle is
    // a failure, so the reader thread always ends up sleeping `backoff_ms`
    // (1000ms on the very first failure) via the real `IoSleeper`. Bounded
    // (not `while (true)`) so this thread reliably returns on its own —
    // relying on `server.deinit()` to unblock a pending `accept()` isn't
    // guaranteed on every backend.
    const RejectServer = struct {
        fn run(srv: *net.Server, io: Io) void {
            const stream = srv.accept(io) catch return;
            stream.close(io);
        }
    };
    const server_thread = try std.Thread.spawn(.{}, RejectServer.run, .{ &server, testing.io });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var callbacks = RecordingCallbacks{};
    var thread_id_dispatcher = ThreadIdDispatcher{};

    const socket_path = try testing.allocator.dupe(u8, path);
    defer testing.allocator.free(socket_path);

    var events_client = EventsClient{
        .gpa = testing.allocator,
        .io = testing.io,
        .socket_path = socket_path,
        .dispatcher = thread_id_dispatcher.dispatcher(),
        .sleeper = undefined, // set below, once `io_sleeper` points at this same client's `.stopping`.
        .on_event = RecordingCallbacks.onEvent,
        .on_resynced = RecordingCallbacks.onResynced,
        .callback_ctx = &callbacks,
    };
    var io_sleeper = IoSleeper{ .io = testing.io, .stopping = &events_client.stopping };
    events_client.sleeper = io_sleeper.sleeper();
    try events_client.start();

    // Let the first failed cycle happen and land inside its 1000ms backoff
    // sleep before asking it to stop.
    Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};

    const start = std.Io.Timestamp.now(testing.io, .awake);
    events_client.stop();
    const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));

    // Regression guard for the un-sliced `Io.sleep(backoff_ms)`: without
    // slicing, this would block for most of the remaining ~900ms.
    try testing.expect(elapsed.nanoseconds < 300 * std.time.ns_per_ms);
}
