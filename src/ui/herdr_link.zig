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

/// Deja la ruta del socket al principio de `buf` y devuelve su longitud.
///
/// Existe como función aparte por un panic real, no por gusto:
/// `client.resolveSocketPath` (`client.zig:64`) tiene tres ramas y **dos de
/// ellas construyen la ruta DENTRO de `buf` y devuelven un slice de ese mismo
/// buffer** (`XDG_CONFIG_HOME` y `HOME`). Solo la rama de `HERDR_SOCKET_PATH`
/// devuelve memoria ajena. Un `@memcpy(buf[0..n], resolved)` aliasea consigo
/// mismo en las dos primeras y Zig 0.16 aborta: `@memcpy arguments alias`.
///
/// `copyForwards` es correcto en las tres: con `dest.ptr == src.ptr` es un
/// no-op, y el destino siempre empieza en el índice 0, así que nunca se pisa
/// hacia atrás.
///
/// El panic no lo vio nadie porque esta máquina exporta `HERDR_SOCKET_PATH`,
/// que es justo la única rama sana. Por eso el test de abajo ejercita las dos.
fn storeSocketPath(buf: *[std.fs.max_path_bytes]u8, environ: std.process.Environ.Map) !usize {
    const resolved = try client.resolveSocketPath(environ, buf);
    std.mem.copyForwards(u8, buf[0..resolved.len], resolved);
    return resolved.len;
}

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

        self.socket_path_len = storeSocketPath(&self.socket_path_buf, environ.*) catch |err| {
            std.log.err("herdr_link: resolveSocketPath failed: {t}", .{err});
            return;
        };

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
            // ponytail: este join bloquea el hilo de UI, y el techo son ~28 s,
            // no los ~13 que decía antes de que el auditor sumara el otro tramo:
            // ~10 s de ventana de lanzamiento + ~3 s de `readHerdrStatus`
            // (`ensureRunning`, herdr ausente), MÁS hasta 15 s si `stop()` llega
            // con el lector dentro de `resync()` → `client.request`, porque
            // `shutdown(.recv)` actúa sobre el fd de la suscripción y no
            // desbloquea el de la petición (`client.zig:88`,
            // `default_read_timeout_ms`). Peor caso: proceso zombi ~28 s tras
            // cerrar la ventana. Cortarlo exige una costura cancelable en
            // `LocalServer.ensureRunning` y otra en `client.request` — issue
            // propio, fuera del territorio de ui-builder.
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

// Aquí vivían dos tests de QA con un servidor herdr falso ("start() then
// immediate stop()" y "full start → resync → stop()"). **Colgaban la suite
// entera**, y se quitaron en vez de dejarlos: el falso servidor espera tres
// `accept` en secuencia —sonda, suscripción, resync— y el test de parada
// inmediata, por su propia definición, no produce los dos últimos; el
// `accept` bloquea para siempre y el `join` del `defer` no vuelve. Cerrar el
// listener antes del join no lo desbloquea en esta implementación de `std.Io`.
//
// Una suite que cuelga es peor que una que falla: no dice qué se rompió y se
// come el job hasta el timeout del runner. Y estos dos escenarios ya estaban
// asignados al gate de integración contra un herdr de verdad, que es donde el
// diseño los puso. Vuelven cuando exista un arnés de servidor falso que
// tolere secuencias parciales — anotado en CONCERNS.md.

test "storeSocketPath: works on both branches — the aliasing one included" {
    // Rama SIN HERDR_SOCKET_PATH: `resolveSocketPath` construye la ruta dentro
    // del buffer y devuelve un slice de él. Es la que abortaba.
    {
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        try env.put("HOME", "/home/tester");

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try storeSocketPath(&buf, env);
        try testing.expectEqualStrings("/home/tester/.config/herdr/herdr.sock", buf[0..len]);
    }

    // Rama CON HERDR_SOCKET_PATH: el slice viene del environ, no del buffer.
    {
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        try env.put("HOME", "/home/tester");
        try env.put("HERDR_SOCKET_PATH", "/run/user/1000/herdr.sock");

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try storeSocketPath(&buf, env);
        try testing.expectEqualStrings("/run/user/1000/herdr.sock", buf[0..len]);
    }

    // Rama XDG_CONFIG_HOME: también construye dentro del buffer.
    {
        var env = std.process.Environ.Map.init(testing.allocator);
        defer env.deinit();
        try env.put("XDG_CONFIG_HOME", "/home/tester/.cfg");

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try storeSocketPath(&buf, env);
        try testing.expectEqualStrings("/home/tester/.cfg/herdr/herdr.sock", buf[0..len]);
    }
}

// Forma propuesta por QA al analizar por qué sus propios tests no podían cazar
// el panic. Es mejor que probar las rutas: fija el CONTRATO. Que
// `resolveSocketPath` devuelva un slice del buffer que recibe no es un
// accidente de implementación —es lo que hace a propósito—, y mientras eso no
// esté escrito en ningún sitio, cada caller nuevo puede volver a intentar un
// `@memcpy` sobre sí mismo. Aquí queda escrito y comprobado.
test "resolveSocketPath: el slice devuelto vive DENTRO del buffer (contrato de alias)" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try client.resolveSocketPath(env, &buf);

    const base = @intFromPtr(&buf);
    const got = @intFromPtr(resolved.ptr);
    try testing.expect(got >= base and got + resolved.len <= base + buf.len);

    // Y el contrapunto: con HERDR_SOCKET_PATH el slice viene de fuera, así que
    // un caller no puede asumir NINGUNA de las dos cosas — tiene que usar una
    // copia que tolere el alias, como hace `storeSocketPath`.
    try env.put("HERDR_SOCKET_PATH", "/run/user/1000/herdr.sock");
    const outside = try client.resolveSocketPath(env, &buf);
    const got2 = @intFromPtr(outside.ptr);
    try testing.expect(got2 < base or got2 >= base + buf.len);
}

// RESTAURADO. Este test existía en `69c9240` y desapareció en `728c352`: el
// hunk que quitaba los dos tests de QA que colgaban la suite se llevó por
// delante el de al lado. Nadie lo notó porque Zig no se queja de una función
// privada sin usar, así que `pumpUntilDrained` quedó huérfano y la suite verde.
// Lo cazó el auditor en la segunda pasada.
//
// Es el único test del escenario Gherkin 6 —"ninguna mutación del Store ocurre
// en el hilo lector"—, o sea la garantía por la que existe este issue, y el
// único que distingue un dispatcher asíncrono de uno síncrono: sin él, alguien
// vuelve a `MainContext.invoke` y la suite sigue en verde.
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
