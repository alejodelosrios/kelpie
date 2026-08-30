//! Autostart for the local `herdr server` — probe via `connect()`, launch as
//! an unowned orphan only when the server was never alive in this process.
//!
//! `ensureRunning` is stateless between calls; the caller owns
//! `ever_connected` (session-level state in `app_shell.zig` / #17).

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const json = std.json;
const Environ = std.process.Environ;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Mode = enum {
    auto,
    /// "Reconectar" button in the UI — ignores the `ever_connected` guard.
    force,
};

pub const Kind = enum {
    /// Server was already alive (`connect()` accepted on the first probe).
    connected,
    /// We launched it and it accepted within the 10 s window.
    launched,
    /// We launched it but it did not accept in time.
    launch_timed_out,
    /// Confirmed dead, `ever_connected == true`, `mode == .auto` — no relaunch.
    stopped_no_autostart,
};

/// `compatible`/`restart_needed` are populated only when `kind` implies a
/// reachable server (`.connected`/`.launched`).  For `.launch_timed_out` and
/// `.stopped_no_autostart` there is nobody to ask — they stay `null`.  If
/// `herdr status --json` fails or does not parse with the server already
/// reachable, they also stay `null`: a compatibility datum that could not be
/// read is not a reason for `ensureRunning` to fail.
pub const Status = struct {
    kind: Kind,
    compatible: ?bool = null,
    restart_needed: ?bool = null,
};

pub const ServerCompat = struct {
    compatible: bool,
    restart_needed: bool,
};

/// Injected to make the launch testable without the real `herdr` binary:
/// receives `socket_path` because a test launcher needs to know where to
/// stand up its `FakeServer`; receives `environ` because the real launcher
/// uses it for `$SHELL` and `$XDG_STATE_HOME`, not for socket resolution
/// (`herdr` resolves that itself).
pub const Launcher = *const fn (io: Io, environ: Environ.Map, socket_path: []const u8) anyerror!void;

/// Injected for the same reason as `Launcher`: the real `herdr` binary is
/// not guaranteed in CI/sandbox.  A `null` return (not error) means "could
/// not read" and is indistinguishable, for `ensureRunning`, from a
/// `herdr status --json` that failed — in both cases `Status.compatible` /
/// `.restart_needed` stay `null`.
pub const StatusReader = *const fn (io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat;

// ---------------------------------------------------------------------------
// Retry constants
// ---------------------------------------------------------------------------

const probe_retry_interval_ms: i64 = 50;
const dead_probe_attempts: u32 = 20; // 20 × 50 ms = 1 s
const launch_probe_attempts: u32 = 200; // 200 × 50 ms = 10 s

// ---------------------------------------------------------------------------
// Real launcher: `$SHELL -lc 'exec herdr server'`
// ---------------------------------------------------------------------------

/// Spawns `herdr server` as an unowned orphan process.  stdout/stderr go to a
/// unique log file under `$XDG_STATE_HOME/kelpie/` (or
/// `$HOME/.local/state/kelpie/`).  The `Child` is never stored — the process
/// is not reaped when kelpie exits (by design: the issue requires "no poseído").
pub fn spawnHerdrServer(io: Io, environ: Environ.Map, socket_path: []const u8) !void {
    _ = socket_path; // herdr resolves its own socket from the environment

    // --- determine log directory ---
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_dir: []const u8 = blk: {
        if (environ.get("XDG_STATE_HOME")) |xdg| {
            const suffix = "/kelpie";
            if (xdg.len + suffix.len > path_buf.len) return error.PathTooLong;
            @memcpy(path_buf[0..xdg.len], xdg);
            @memcpy(path_buf[xdg.len..][0..suffix.len], suffix);
            break :blk path_buf[0 .. xdg.len + suffix.len];
        }
        const home = environ.get("HOME") orelse return error.HomeNotSet;
        const suffix = "/.local/state/kelpie";
        if (home.len + suffix.len > path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..home.len], home);
        @memcpy(path_buf[home.len..][0..suffix.len], suffix);
        break :blk path_buf[0 .. home.len + suffix.len];
    };

    try Io.Dir.cwd().createDirPath(io, state_dir);

    // --- unique log filename ---
    const ts = Io.Timestamp.now(io, .awake).nanoseconds;
    var log_name_buf: [128]u8 = undefined;
    const log_name = try std.fmt.bufPrint(&log_name_buf, "herdr-server-{d}.log", .{ts});

    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (state_dir.len + 1 + log_name.len > log_path_buf.len) return error.PathTooLong;
    @memcpy(log_path_buf[0..state_dir.len], state_dir);
    log_path_buf[state_dir.len] = '/';
    @memcpy(log_path_buf[state_dir.len + 1 ..][0..log_name.len], log_name);
    const log_path = log_path_buf[0 .. state_dir.len + 1 + log_name.len];

    const log_file = try Io.Dir.createFileAbsolute(io, log_path, .{});
    // Fork/dup2 does NOT close the parent's fd for `.file` — caller must
    // close it after spawn.  (Threaded.zig:14900-15095, spawnPosix)
    defer log_file.close(io);

    // --- shell ---
    const shell = environ.get("SHELL") orelse "/bin/sh";

    // --- spawn ---
    // The argv lives on our stack — spawn() forks before it returns, so the
    // child has its own copy of the argument pointers.
    const argv = [_][]const u8{ shell, "-lc", "exec herdr server" };
    _ = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        .environ_map = &environ,
    });
    // Child is discarded — unowned orphan, never waited/killed.
}

// ---------------------------------------------------------------------------
// Real status reader: `herdr status --json`
// ---------------------------------------------------------------------------

/// Runs `herdr status --json`, parses the `server.compatible` and
/// `server.restart_needed` fields.  Any failure (spawn, non-zero exit, JSON
/// that does not parse) is swallowed and `null` is returned — never propagates
/// an error.
pub fn readHerdrStatus(io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat {
    const argv = [_][]const u8{ "herdr", "status", "--json" };
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .environ_map = &environ,
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return null;

    const StatusJson = struct {
        server: struct {
            compatible: bool,
            restart_needed: bool,
        },
    };

    const parsed = json.parseFromSlice(StatusJson, gpa, result.stdout, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    return ServerCompat{
        .compatible = parsed.value.server.compatible,
        .restart_needed = parsed.value.server.restart_needed,
    };
}

// ---------------------------------------------------------------------------
// Core logic
// ---------------------------------------------------------------------------

/// Probe `socket_path` once via `connect()`.  Closes the probe stream
/// immediately on success.  Returns `void` on success, or the connect error.
fn tryConnect(io: Io, socket_path: []const u8) !void {
    const addr = try net.UnixAddress.init(socket_path);
    const stream = try addr.connect(io);
    stream.close(io);
}

/// Decide whether the local `herdr server` is alive, launch it if needed,
/// and return the outcome.
///
/// `ever_connected` is session-level state owned by the caller (true once
/// this process has ever successfully connected to the server).
pub fn ensureRunning(
    io: Io,
    gpa: std.mem.Allocator,
    environ: Environ.Map,
    socket_path: []const u8,
    mode: Mode,
    ever_connected: bool,
    launch: Launcher,
    status_reader: StatusReader,
) !Status {
    // --- Step 1: first probe ---
    tryConnect(io, socket_path) catch |first_err| {
        // --- Step 2: FileNotFound → never started, skip retry window ---
        if (first_err == error.FileNotFound) return try launchAndProbe(
            io,
            gpa,
            environ,
            socket_path,
            launch,
            status_reader,
        );

        // --- Step 3: ambiguous error → retry for ~1 s ---
        // A dead socket (listener closed without unlinking) produces
        // error.Unexpected on the AF_UNIX path (posixConnectUnix in
        // Threaded.zig:11947-11987 has no ECONNREFUSED branch).
        var attempts: u32 = 0;
        while (attempts < dead_probe_attempts) : (attempts += 1) {
            Io.sleep(io, .fromMilliseconds(probe_retry_interval_ms), .awake) catch |e| return e;
            tryConnect(io, socket_path) catch continue;
            // Server came back during the retry window.
            return statusWithCompat(io, gpa, environ, .connected, status_reader);
        }
        // All retries failed — confirmed dead.
        return try afterConfirmedDead(io, gpa, environ, socket_path, mode, ever_connected, launch, status_reader);
    };

    // --- Step 1 success: server was already alive ---
    return statusWithCompat(io, gpa, environ, .connected, status_reader);
}

/// Called after the server is confirmed dead (all probes failed).
fn afterConfirmedDead(
    io: Io,
    gpa: std.mem.Allocator,
    environ: Environ.Map,
    socket_path: []const u8,
    mode: Mode,
    ever_connected: bool,
    launch: Launcher,
    status_reader: StatusReader,
) !Status {
    // --- Step 4: guard ---
    if (mode == .auto and ever_connected) {
        return Status{ .kind = .stopped_no_autostart };
    }

    // --- Step 5: launch + probe ---
    return try launchAndProbe(io, gpa, environ, socket_path, launch, status_reader);
}

/// Launch the server and probe for up to 10 s.
fn launchAndProbe(
    io: Io,
    gpa: std.mem.Allocator,
    environ: Environ.Map,
    socket_path: []const u8,
    launch: Launcher,
    status_reader: StatusReader,
) !Status {
    try launch(io, environ, socket_path);

    var attempts: u32 = 0;
    while (attempts < launch_probe_attempts) : (attempts += 1) {
        Io.sleep(io, .fromMilliseconds(probe_retry_interval_ms), .awake) catch |e| return e;
        tryConnect(io, socket_path) catch continue;
        return statusWithCompat(io, gpa, environ, .launched, status_reader);
    }
    return Status{ .kind = .launch_timed_out };
}

/// Build a `Status` with the given `kind` and, if the server is reachable,
/// read `compatible`/`restart_needed` via the injected `status_reader`.
fn statusWithCompat(
    io: Io,
    gpa: std.mem.Allocator,
    environ: Environ.Map,
    kind: Kind,
    status_reader: StatusReader,
) Status {
    const compat = status_reader(io, gpa, environ);
    return Status{
        .kind = kind,
        .compatible = if (compat) |c| c.compatible else null,
        .restart_needed = if (compat) |c| c.restart_needed else null,
    };
}

// ===========================================================================
// Tests — Gherkin scenarios from roadmap/designs/11-local-server-autostart.md
// ===========================================================================

const testing = std.testing;

// ---------------------------------------------------------------------------
// Test helpers: FakeServer, test Launcher, test StatusReader
// ---------------------------------------------------------------------------

/// A minimal server that listens on a Unix socket and accepts exactly one
/// connection, then closes it.  Same pattern as `client.zig`'s FakeServer.
fn fakeServerAcceptOne(server: *net.Server, io: Io) void {
    const stream = server.accept(io) catch return;
    stream.close(io);
}

var test_server_next_id: std.atomic.Value(u32) = .init(0);

/// Create a unique `/tmp` socket path.
fn testSocketPath(buf: *[108]u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "/tmp/kelpie-ls-{d}-{d}.sock",
        .{ std.posix.system.getpid(), test_server_next_id.fetchAdd(1, .monotonic) },
    );
}

// --- test Launcher that starts a FakeServer ---

var launcher_server: net.Server = undefined;
var launcher_thread: ?std.Thread = null;

fn testLauncher(io: Io, environ: Environ.Map, socket_path: []const u8) !void {
    _ = environ;
    // Delete stale socket file if it exists (dead socket tests leave one behind).
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    const addr = try net.UnixAddress.init(socket_path);
    launcher_server = try addr.listen(io, .{});
    launcher_thread = try std.Thread.spawn(.{}, fakeServerAcceptOne, .{ &launcher_server, io });
}

/// Clean up the FakeServer started by `testLauncher`.
/// Joins first (thread exits after accepting one connection), then deinits.
fn cleanupTestLauncher() void {
    if (launcher_thread) |t| {
        t.join();
        launcher_thread = null;
    }
    launcher_server.deinit(testing.io);
}

// --- test StatusReader helpers ---

fn statusReaderReturns(compat: ServerCompat) StatusReader {
    const S = struct {
        var cached_compat: ServerCompat = undefined;
        fn read(io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat {
            _ = io;
            _ = gpa;
            _ = environ;
            return cached_compat;
        }
    };
    S.cached_compat = compat;
    return S.read;
}

fn statusReaderNull(io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat {
    _ = io;
    _ = gpa;
    _ = environ;
    return null;
}

var status_reader_called: bool = false;

fn statusReaderTracking(io: Io, gpa: std.mem.Allocator, environ: Environ.Map) ?ServerCompat {
    _ = io;
    _ = gpa;
    _ = environ;
    status_reader_called = true;
    return null;
}

// --- no-op launcher (for .connected tests where server is already up) ---

fn noopLauncher(io: Io, environ: Environ.Map, socket_path: []const u8) !void {
    _ = io;
    _ = environ;
    _ = socket_path;
    return error.ShouldNotBeCalled;
}

// ---------------------------------------------------------------------------
// Scenario: Sin herdr.sock, kelpie arranca el servidor y conecta
// ---------------------------------------------------------------------------

test "ensureRunning: no socket → launcher starts server → .launched" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        testLauncher,
        statusReaderNull,
    );

    cleanupTestLauncher();
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    try testing.expectEqual(Kind.launched, status.kind);
    try testing.expect(status.compatible == null);
    try testing.expect(status.restart_needed == null);
}

// ---------------------------------------------------------------------------
// Scenario: compatible/restart_needed se leen vía el StatusReader
// ---------------------------------------------------------------------------

test "ensureRunning: StatusReader populates compatible/restart_needed" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        testLauncher,
        statusReaderReturns(.{ .compatible = false, .restart_needed = true }),
    );

    cleanupTestLauncher();
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    try testing.expectEqual(Kind.launched, status.kind);
    try testing.expect(status.compatible == false);
    try testing.expect(status.restart_needed == true);
}

// ---------------------------------------------------------------------------
// Scenario: StatusReader que devuelve null no cambia el Kind
// ---------------------------------------------------------------------------

test "ensureRunning: null StatusReader leaves compatible/restart_needed null" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        testLauncher,
        statusReaderNull,
    );

    cleanupTestLauncher();
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    try testing.expectEqual(Kind.launched, status.kind);
    try testing.expect(status.compatible == null);
    try testing.expect(status.restart_needed == null);
}

// ---------------------------------------------------------------------------
// Scenario: StatusReader nunca se invoca si el servidor no es alcanzable
// ---------------------------------------------------------------------------

test "ensureRunning: stopped_no_autostart never calls StatusReader" {
    // Create a dead socket: bind + close without accepting.
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);
    const addr = try net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    server.deinit(testing.io);
    // Socket file still exists on disk but no one is listening.
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    status_reader_called = false;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        true, // ever_connected
        noopLauncher,
        statusReaderTracking,
    );

    try testing.expectEqual(Kind.stopped_no_autostart, status.kind);
    try testing.expect(status.compatible == null);
    try testing.expect(status.restart_needed == null);
    try testing.expect(!status_reader_called);
}

// ---------------------------------------------------------------------------
// Scenario: Socket muerto (bind-then-kill), kelpie espera ~1s y arranca
// ---------------------------------------------------------------------------

test "ensureRunning: dead socket → ~1s retry window → launcher called" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);
    const addr = try net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    server.deinit(testing.io);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const start = Io.Timestamp.now(testing.io, .awake);
    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        testLauncher,
        statusReaderNull,
    );
    const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake));

    cleanupTestLauncher();

    // The retry window is 20 × 50 ms = 1000 ms.  Allow some slack for
    // scheduling jitter: >= 900 ms, < 3000 ms.
    try testing.expect(elapsed.nanoseconds >= 900 * std.time.ns_per_ms);
    try testing.expect(elapsed.nanoseconds < 3000 * std.time.ns_per_ms);

    try testing.expectEqual(Kind.launched, status.kind);
}

// ---------------------------------------------------------------------------
// Scenario: herdr server stop con kelpie abierto — .auto vs .force
// ---------------------------------------------------------------------------

test "ensureRunning: dead socket + ever_connected + .auto → stopped_no_autostart" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);
    const addr = try net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    server.deinit(testing.io);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        true,
        noopLauncher,
        statusReaderNull,
    );

    try testing.expectEqual(Kind.stopped_no_autostart, status.kind);
}

test "ensureRunning: dead socket + ever_connected + .force → launches" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);
    const addr = try net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    server.deinit(testing.io);
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .force, // force ignores the guard
        true,
        testLauncher,
        statusReaderNull,
    );

    cleanupTestLauncher();

    try testing.expectEqual(Kind.launched, status.kind);
}

// ---------------------------------------------------------------------------
// Scenario (QA addition — not in the design's Gherkin list, but the launch
// window's ~10s/200-attempt timeout path had zero coverage): launcher that
// never brings up a listener → ensureRunning spends the full ~10s window
// before giving up with .launch_timed_out, not a shortcut.
// ---------------------------------------------------------------------------

fn noListenerLauncher(io: Io, environ: Environ.Map, socket_path: []const u8) !void {
    _ = io;
    _ = environ;
    _ = socket_path; // deliberately never create the socket
}

test "ensureRunning: launcher never listens → ~10s launch window → .launch_timed_out" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    const start = Io.Timestamp.now(testing.io, .awake);
    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        noListenerLauncher,
        statusReaderNull,
    );
    const elapsed = start.durationTo(Io.Timestamp.now(testing.io, .awake));

    // The launch window is 200 × 50 ms = 10 s. Assert real time was spent
    // (not just the final Kind), same slack pattern as the ~1s dead-socket
    // test: >= 9s, < 20s.
    try testing.expect(elapsed.nanoseconds >= 9 * std.time.ns_per_s);
    try testing.expect(elapsed.nanoseconds < 20 * std.time.ns_per_s);

    try testing.expectEqual(Kind.launch_timed_out, status.kind);
    try testing.expect(status.compatible == null);
    try testing.expect(status.restart_needed == null);
}

// ---------------------------------------------------------------------------
// Scenario: server already alive → .connected (no launcher called)
// ---------------------------------------------------------------------------

test "ensureRunning: server already alive → .connected, launcher never called" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    // Start a server that stays alive for the whole test.
    const addr = try net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    // Accept exactly one connection (the probe from ensureRunning) then exit.
    const accept_thread = try std.Thread.spawn(.{}, fakeServerAcceptOne, .{ &server, testing.io });

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        noopLauncher, // would error if called
        statusReaderNull,
    );

    // Thread exited after accepting the probe connection.
    accept_thread.join();
    server.deinit(testing.io);

    try testing.expectEqual(Kind.connected, status.kind);
}

// ---------------------------------------------------------------------------
// Scenario: server already alive + StatusReader with compat data
// ---------------------------------------------------------------------------

test "ensureRunning: .connected with StatusReader populates compat fields" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    const addr = try net.UnixAddress.init(path);
    var server = try addr.listen(testing.io, .{});
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    const accept_thread = try std.Thread.spawn(.{}, fakeServerAcceptOne, .{ &server, testing.io });

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        noopLauncher,
        statusReaderReturns(.{ .compatible = true, .restart_needed = false }),
    );

    accept_thread.join();
    server.deinit(testing.io);

    try testing.expectEqual(Kind.connected, status.kind);
    try testing.expect(status.compatible == true);
    try testing.expect(status.restart_needed == false);
}

// ---------------------------------------------------------------------------
// Scenario: .launched with StatusReader populates compat fields
// ---------------------------------------------------------------------------

test "ensureRunning: .launched with StatusReader populates compat fields" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        testLauncher,
        statusReaderReturns(.{ .compatible = true, .restart_needed = false }),
    );

    cleanupTestLauncher();
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    try testing.expectEqual(Kind.launched, status.kind);
    try testing.expect(status.compatible == true);
    try testing.expect(status.restart_needed == false);
}

// ---------------------------------------------------------------------------
// Scenario: .launched with null StatusReader
// ---------------------------------------------------------------------------

test "ensureRunning: .launched with null StatusReader leaves compat null" {
    var path_buf: [108]u8 = undefined;
    const path = try testSocketPath(&path_buf);

    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();

    launcher_server = undefined;
    launcher_thread = null;

    const status = try ensureRunning(
        testing.io,
        testing.allocator,
        env,
        path,
        .auto,
        false,
        testLauncher,
        statusReaderNull,
    );

    cleanupTestLauncher();
    defer std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};

    try testing.expectEqual(Kind.launched, status.kind);
    try testing.expect(status.compatible == null);
    try testing.expect(status.restart_needed == null);
}
