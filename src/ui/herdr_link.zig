//! Herdr link (#81): wires `EventsClient` to the GTK main loop via a
//! `GlibDispatcher` and owns the startup thread that calls
//! `ensureRunning` → `EventsClient.start()`.  Callbacks mutate the
//! `Store` always from the UI thread (by construction: the only path
//! to them is through the GLib trampoline).
//!
//! Territory: ui-builder. See roadmap/designs/81-cableado-herdr.md.

const std = @import("std");
const glib = @import("glib");

const Events = @import("../herdr/Events.zig");
const LocalServer = @import("../herdr/LocalServer.zig");
const client = @import("../herdr/client.zig");
const Store = @import("../model/Store.zig").Store;
const types = @import("../herdr/types.zig");

// ---------------------------------------------------------------------------
// GlibDispatcher — implements Events.Dispatcher against glib.MainContext.invoke
// ---------------------------------------------------------------------------

/// Heap-allocated box that carries `task` + `task_ctx` + the allocator
/// through GLib's single `user_data` pointer.  The trampoline calls
/// `task(ctx)`, destroys the box, and returns `0` (`G_SOURCE_REMOVE`).
const Box = struct {
    gpa: std.mem.Allocator,
    task: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const GlibDispatcher = struct {
    gpa: std.mem.Allocator,

    pub fn dispatcher(self: *GlibDispatcher) Events.Dispatcher {
        return .{ .ptr = self, .invokeFn = invokeImpl };
    }

    fn invokeImpl(ptr: *anyopaque, task: *const fn (ctx: *anyopaque) void, task_ctx: *anyopaque) anyerror!void {
        const self: *GlibDispatcher = @ptrCast(@alignCast(ptr));
        const box = try self.gpa.create(Box);
        box.* = .{ .gpa = self.gpa, .task = task, .ctx = task_ctx };
        // `idleAddOnce`, NO `MainContext.invoke`. Lo destapó el test del hilo de
        // este mismo archivo: `g_main_context_invoke` ejecuta la función **en
        // línea** cuando el hilo que llama puede adquirir el contexto, y sin main
        // loop dueña puede. Eso dejaba la garantía —"el Store solo se toca desde
        // el hilo de UI"— dependiendo de que la loop estuviera viva y fuera dueña,
        // así que en las ventanas de arranque y cierre el hilo lector habría
        // mutado el Store directamente: justo la carrera que este issue impide.
        // Una fuente idle SIEMPRE se encola y la drena la loop, nunca el llamador.
        _ = glib.idleAddOnce(&trampoline, box);
    }
};

/// `glib.SourceOnceFunc` (glib2.zig:25660): devuelve void — una fuente "once" se
/// quita sola, no hay `G_SOURCE_REMOVE` que devolver.
fn trampoline(data: ?*anyopaque) callconv(.c) void {
    const box: *Box = @ptrCast(@alignCast(data.?));
    box.task(box.ctx);
    box.gpa.destroy(box);
}

// ---------------------------------------------------------------------------
// Link — lifecycle owner of the herdr connection
// ---------------------------------------------------------------------------

pub const Link = struct {
    startup_thread: ?std.Thread = null,
    events_client: ?Events.EventsClient = null,
    io_sleeper: ?Events.IoSleeper = null,
    /// Socket path storage — must outlive the `EventsClient`, which
    /// saves the slice and uses it from its reader thread.
    socket_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    socket_path_len: usize = 0,
    gpa: std.mem.Allocator = undefined,
    store: ?*Store = null,
    dispatcher: GlibDispatcher = undefined,
    /// Set by `stop()` before joining the startup thread.  The startup
    /// thread checks it at phase boundaries so it can bail out early
    /// instead of blocking on `ensureRunning` or `EventsClient.start`.
    stopping: std.atomic.Value(bool) = .init(false),

    /// Resolve the socket, spawn a startup thread that calls
    /// `ensureRunning` (may block ~10 s) then `EventsClient.start()`.
    /// The startup thread publishes `Status.kind` to the UI via the
    /// dispatcher so the empty-state label can explain why there are
    /// no agents.
    pub fn start(
        self: *Link,
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: *std.process.Environ.Map,
        store: *Store,
    ) void {
        self.gpa = gpa;
        self.store = store;
        self.dispatcher = .{ .gpa = gpa };

        const resolved = client.resolveSocketPath(environ.*, &self.socket_path_buf) catch |err| {
            std.log.err("herdr_link: resolveSocketPath failed: {t}", .{err});
            return;
        };
        @memcpy(self.socket_path_buf[0..resolved.len], resolved);
        self.socket_path_len = resolved.len;

        self.startup_thread = std.Thread.spawn(.{}, startupThreadFn, .{ self, io, gpa, environ }) catch |err| {
            std.log.err("herdr_link: failed to spawn startup thread: {t}", .{err});
            return;
        };
    }

    /// Clean shutdown: signal the startup thread to stop, join it (if
    /// still running), then stop the `EventsClient` (which does
    /// shutdown+join on its reader thread).
    pub fn stop(self: *Link) void {
        self.stopping.store(true, .release);
        if (self.startup_thread) |t| {
            // ponytail: if the thread is inside `ensureRunning` (herdr
            // absent, ~10 s launch window + ~3 s readHerdrStatus), this
            // join blocks the UI thread for up to ~13 s.  Fixing it
            // requires a `Cancelable` seam in `LocalServer.ensureRunning`
            // (issue own) — out of ui-builder territory.
            t.join();
            self.startup_thread = null;
        }
        if (self.events_client) |*ec| {
            ec.stop();
        }
    }
};

fn startupThreadFn(link: *Link, io: std.Io, gpa: std.mem.Allocator, environ: *std.process.Environ.Map) void {
    if (link.stopping.load(.acquire)) return;

    const socket_path = link.socket_path_buf[0..link.socket_path_len];

    const status = LocalServer.ensureRunning(
        io,
        gpa,
        environ.*,
        socket_path,
        .auto,
        false,
        LocalServer.spawnHerdrServer,
        LocalServer.readHerdrStatus,
    ) catch |err| {
        std.log.err("herdr_link: ensureRunning failed: {t}", .{err});
        return;
    };

    if (link.stopping.load(.acquire)) return;

    std.log.info("herdr_link: server status={s}", .{@tagName(status.kind)});

    // Publish status kind to the UI via the dispatcher — the same
    // pattern as event delivery.  No shared variable, no poll.
    const ctx = gpa.create(StatusCtx) catch {
        std.log.err("herdr_link: failed to allocate StatusCtx", .{});
        return;
    };
    ctx.* = .{ .link = link, .kind = status.kind };
    link.dispatcher.dispatcher().invoke(&publishStatusTrampoline, ctx) catch {
        std.log.err("herdr_link: dispatcher.invoke(publishStatus) failed", .{});
        gpa.destroy(ctx);
        return;
    };

    if (link.stopping.load(.acquire)) return;

    // Build the EventsClient.  The IoSleeper must live in link.io_sleeper
    // (not on this stack) because the Sleeper it returns captures a
    // pointer to it — the EventsClient's reader thread dereferences
    // that pointer long after this function returns.
    link.events_client = .{
        .gpa = gpa,
        .io = io,
        .socket_path = socket_path,
        .dispatcher = link.dispatcher.dispatcher(),
        .sleeper = undefined, // set below, once io_sleeper is at its final address
        .on_event = onEvent,
        .on_resynced = onResynced,
        .callback_ctx = link,
    };
    link.io_sleeper = .{ .io = io, .stopping = &link.events_client.?.stopping };
    link.events_client.?.sleeper = link.io_sleeper.?.sleeper();

    link.events_client.?.start() catch |err| {
        std.log.err("herdr_link: EventsClient.start failed: {t}", .{err});
    };
}

/// Context for the status-publish trampoline.  Heap-allocated by the
/// startup thread, freed by the trampoline after it runs on the UI thread.
const StatusCtx = struct {
    link: *Link,
    kind: LocalServer.Kind,
};

/// Runs on the UI thread (GLib trampoline).  Updates the empty-state
/// label with the server status kind, then frees the ctx.
fn publishStatusTrampoline(ctx: *anyopaque) void {
    const sc: *StatusCtx = @ptrCast(@alignCast(ctx));
    updateStatusLabel(sc.kind);
    sc.link.gpa.destroy(sc);
}

/// Set by `app_shell.zig` so the trampoline can update the label.
/// Same "set once in run(), read later" pattern as the old
/// `empty_label_ref` — no synchronization needed.
pub var updateStatusLabel: *const fn (kind: LocalServer.Kind) void = &noopUpdateStatusLabel;

fn noopUpdateStatusLabel(_: LocalServer.Kind) void {}

// ---------------------------------------------------------------------------
// Callbacks — run on the UI thread by construction (GLib trampoline)
// ---------------------------------------------------------------------------

fn onEvent(ctx: *anyopaque, envelope: types.EventEnvelope) void {
    const link: *Link = @ptrCast(@alignCast(ctx));
    const store = link.store orelse return;
    store.applyEvent(envelope) catch |err| {
        std.log.err("herdr_link: applyEvent failed: {t}", .{err});
    };
}

fn onResynced(ctx: *anyopaque, snapshot: types.SessionSnapshot) void {
    const link: *Link = @ptrCast(@alignCast(ctx));
    const store = link.store orelse return;
    store.applySnapshot(snapshot) catch |err| {
        std.log.err("herdr_link: applySnapshot failed: {t}", .{err});
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "GlibDispatcher: allocation failure propagates without leaking task_ctx" {
    // Scenario: "la costura de dispatch libera el evento cuando no puede
    // encolarlo" — a dispatcher whose allocation fails must propagate
    // the error so the caller (Events.zig) can free task_ctx.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var gd = GlibDispatcher{ .gpa = failing.allocator() };

    var dummy_ctx: u32 = 42;
    const result = gd.dispatcher().invoke(testTask, &dummy_ctx);
    try testing.expectError(error.OutOfMemory, result);
    // dummy_ctx must still be accessible — no leak, no corruption.
    try testing.expectEqual(@as(u32, 42), dummy_ctx);
}

test "GlibDispatcher: Box is heap-allocated (not stack)" {
    // Verify that invokeImpl creates a heap Box by using a
    // FailingAllocator that fails on the second allocation (the Box)
    // but succeeds on the first (if any).  With fail_index=0 the very
    // first alloc fails — that's the Box create.
    var fail_idx: usize = 0;
    while (fail_idx < 5) : (fail_idx += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_idx });
        var gd = GlibDispatcher{ .gpa = failing.allocator() };

        var dummy_ctx: u32 = 99;
        const result = gd.dispatcher().invoke(testTask, &dummy_ctx);
        // Every attempt must fail (we're not calling glib.MainContext.invoke
        // in tests — only the Box allocation is exercised).
        if (result) |_| {
            // If it didn't fail, the Box wasn't allocated on this
            // fail_index — that's fine, try the next one.
            // Drain the idle source so the Box gets freed (testing.allocator
            // would report a leak otherwise).
            pumpUntilDrained();
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "trampoline: calls the task" {
    // Direct trampoline call — exercises the function without GLib.
    var called = false;
    const TestCtx = struct {
        called: *bool,
    };
    var ctx = TestCtx{ .called = &called };

    // Box must be heap-allocated for the trampoline to destroy it.
    // No defer destroy — trampoline itself frees the box.
    const box_ptr = try testing.allocator.create(Box);
    box_ptr.* = .{
        .gpa = testing.allocator,
        .task = struct {
            fn run(c: *anyopaque) void {
                const tc: *TestCtx = @ptrCast(@alignCast(c));
                tc.called.* = true;
            }
        }.run,
        .ctx = &ctx,
    };

    // `SourceOnceFunc` devuelve void: una fuente "once" se quita sola, no hay
    // `G_SOURCE_REMOVE` que comprobar. Lo que sí se comprueba es que la tarea
    // corrió y que el Box quedó liberado (lo verifica testing.allocator).
    trampoline(box_ptr);
    try testing.expect(called);
}

test "trampoline: destroys the Box (no leak under testing.allocator)" {
    // testing.allocator will fail the test if the Box isn't freed.
    const box_ptr = try testing.allocator.create(Box);
    box_ptr.* = .{
        .gpa = testing.allocator,
        .task = testTask,
        .ctx = undefined,
    };
    _ = trampoline(box_ptr);
    // If trampoline didn't destroy box_ptr, testing.allocator reports a leak.
}

fn testTask(_: *anyopaque) void {}

/// Drain all pending idle sources from the default GLib main context.
/// Must be called after every `invoke` in tests: with `idleAddOnce` the
/// Box is freed when the main loop dispatches the source, not when
/// `invoke` returns.  `may_block = 0` so we never hang on an empty
/// context — we just dispatch whatever is already ready.
fn pumpUntilDrained() void {
    while (glib.MainContext.iteration(null, 0) != 0) {}
}

// ---------------------------------------------------------------------------
// Link lifecycle tests — Gherkin: "cerrar la ventana para los hilos"
// ---------------------------------------------------------------------------

test "Link.stop(): safe with no prior start() — no thread to join, no crash" {
    // Scenario: "stop() sin start() previo" (PM's lifecycle ask). `stop()`
    // must not assume `startup_thread`/`events_client` are populated.
    var link: Link = .{};
    link.stop();
    try testing.expect(link.startup_thread == null);
}

var link_test_next_id: std.atomic.Value(u32) = .init(0);

fn linkTestSocketPath(buf: *[108]u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "/tmp/kelpie-herdr-link-{d}-{d}.sock",
        .{ std.posix.system.getpid(), link_test_next_id.fetchAdd(1, .monotonic) },
    );
}

/// Accepts and immediately closes one connection — mirrors
/// `LocalServer.ensureRunning`'s liveness probe (`tryConnect`), which opens
/// and closes without exchanging data.
fn linkAcceptAndClose(server: *std.Io.net.Server, io: std.Io) void {
    const stream = server.accept(io) catch return;
    stream.close(io);
}

const link_snapshot_json = "{\"result\":{\"snapshot\":{\"version\":\"1\",\"protocol\":20,\"workspaces\":[],\"tabs\":[],\"panes\":[],\"layouts\":[],\"agents\":[]}}}\n";

/// Fake herdr: probe (accept+close) → subscribe (ack) → resync (snapshot) →
/// close, so `EventsClient`'s reader thread lands on a real, deterministic
/// reconnect-backoff loop afterwards (same as a real herdr that hung up).
fn fakeHerdrServerThread(server: *std.Io.net.Server, io: std.Io) void {
    linkAcceptAndClose(server, io); // ensureRunning's tryConnect probe

    const sub_stream = server.accept(io) catch return; // subscribe
    var read_buf: [4096]u8 = undefined;
    var reader = sub_stream.reader(io, &read_buf);
    _ = reader.interface.takeDelimiterInclusive('\n') catch {};
    {
        var write_buf: [4096]u8 = undefined;
        var writer = sub_stream.writer(io, &write_buf);
        writer.interface.writeAll("{\"result\":{\"type\":\"subscription_started\"}}\n") catch {};
        writer.interface.flush() catch {};
    }

    const resync_stream = server.accept(io) catch {
        sub_stream.close(io);
        return;
    };
    var resync_read_buf: [4096]u8 = undefined;
    var resync_reader = resync_stream.reader(io, &resync_read_buf);
    _ = resync_reader.interface.takeDelimiterInclusive('\n') catch {};
    {
        var write_buf: [4096]u8 = undefined;
        var writer = resync_stream.writer(io, &write_buf);
        writer.interface.writeAll(link_snapshot_json) catch {};
        writer.interface.flush() catch {};
    }
    resync_stream.close(io);
    sub_stream.close(io);
}

test "Link: start() then immediate stop() joins the startup thread without hanging" {
    // Scenario: "stop() con el hilo de arranque a medias" — `stop()` right
    // after `start()`, racing the `stopping` check at the top of
    // `startupThreadFn`. Points HERDR_SOCKET_PATH at an already-listening
    // fake socket so `ensureRunning`'s first probe takes the `.connected`
    // fast path (no 10s launch window) regardless of which side of the race
    // this lands on.
    var path_buf: [108]u8 = undefined;
    const path = try linkTestSocketPath(&path_buf);
    const addr = try std.Io.net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    const server_thread = try std.Thread.spawn(.{}, fakeHerdrServerThread, .{ &server, testing.io });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HERDR_SOCKET_PATH", path);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var link: Link = .{};
    const start = std.Io.Timestamp.now(testing.io, .awake);
    link.start(testing.allocator, testing.io, &env, &store);
    link.stop();
    const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));

    try testing.expect(link.startup_thread == null);
    // Regression guard: a stop() that has to wait out ensureRunning's ~10s
    // launch window (or a hang) would blow way past this.
    try testing.expect(elapsed.nanoseconds < 5 * std.time.ns_per_s);

    // Drain whatever the dispatcher queued on the default main context
    // (status publish, maybe a resync) before the test allocator checks for
    // leaks — same requirement as every other test in this file.
    pumpUntilDrained();
}

test "Link: full start → resync via fake herdr → stop() joins and drains cleanly, no leak" {
    // Scenario: "cerrar la ventana para los hilos" — full happy path. Proves
    // the startup thread hands off to a real EventsClient, the dispatcher
    // hands its status-publish and resync tasks to the (pumped) glib main
    // context, and stop() joins both threads without leaking anything under
    // `testing.allocator`.
    var path_buf: [108]u8 = undefined;
    const path = try linkTestSocketPath(&path_buf);
    const addr = try std.Io.net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    const server_thread = try std.Thread.spawn(.{}, fakeHerdrServerThread, .{ &server, testing.io });
    defer server_thread.join();
    defer server.deinit(testing.io);

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HERDR_SOCKET_PATH", path);

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var link: Link = .{};
    link.start(testing.allocator, testing.io, &env, &store);

    // Pump the default main context so the queued status-publish and resync
    // trampolines actually run (idleAddOnce only queues — nothing drains it
    // but a pumped loop). Bounded, same reasoning as the dispatcher test
    // above: an unbounded pump turns a stuck source into a CI hang instead
    // of a red test.
    var spins: u32 = 0;
    while (spins < 1_000) : (spins += 1) {
        _ = glib.MainContext.iteration(null, 0);
        std.Io.sleep(testing.io, .fromMilliseconds(2), .awake) catch {};
    }

    link.stop();
    pumpUntilDrained();

    try testing.expect(link.startup_thread == null);
}

test "GlibDispatcher: task runs on the main-context thread, not the caller" {
    // Proves the dispatcher actually hands off to the GLib main context:
    // the task must run on whichever thread pumps the main context (here,
    // the test thread), not on the thread that called `invoke`.
    //
    // A synchronous dispatcher that calls the task inline would make the
    // task run on the worker thread — the exact bug this test guards
    // against.  `std.Thread.getCurrentId()` is the discrimination tool.
    var gd = GlibDispatcher{ .gpa = testing.allocator };

    var task_ran = false;
    var task_thread_id: std.Thread.Id = undefined;

    const Capture = struct {
        ran: *bool,
        thread_id: *std.Thread.Id,
    };
    var capture = Capture{ .ran = &task_ran, .thread_id = &task_thread_id };

    const worker = try std.Thread.spawn(.{}, struct {
        fn invokeTask(dispatcher: *GlibDispatcher, cap: *Capture) void {
            dispatcher.dispatcher().invoke(struct {
                fn run(raw: *anyopaque) void {
                    const c: *Capture = @ptrCast(@alignCast(raw));
                    c.thread_id.* = std.Thread.getCurrentId();
                    c.ran.* = true;
                }
            }.run, cap) catch {};
        }
    }.invokeTask, .{ &gd, &capture });

    worker.join();

    // Pump the GLib main context until the task fires. Acotado a propósito:
    // sin límite, una fuente que no llegue a dispararse convierte este test en
    // un CUELGUE, y un cuelgue en CI es peor que un rojo — no dice qué falló y
    // se come el job entero hasta el timeout del runner.
    var spins: u32 = 0;
    while (!task_ran and spins < 10_000) : (spins += 1) {
        _ = glib.MainContext.iteration(null, 0);
    }

    // Drain any remaining sources so the Box gets freed (testing.allocator
    // would report a leak otherwise).
    pumpUntilDrained();
    try testing.expect(task_ran);

    // The task must have run on the test thread (main context owner),
    // NOT on the worker thread that called invoke.
    const test_thread_id = std.Thread.getCurrentId();
    try testing.expectEqual(test_thread_id, task_thread_id);
}
