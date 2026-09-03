//! Attach to a local herdr agent pane via `omarchy launch or focus tui`.
//!
//! Pure argv construction (no shell string), spawn as unowned orphan,
//! and protocol-compat guard before opening a window.

const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;
const LocalServer = @import("LocalServer.zig");

// ---------------------------------------------------------------------------
// Public constants
// ---------------------------------------------------------------------------

pub const attach_app_id_prefix = "io.github.alejodelosrios.kelpie.attach.";

// ---------------------------------------------------------------------------
// Pure helpers (testable without GTK or a real process)
// ---------------------------------------------------------------------------

/// Formats `"--app-id=<prefix><pane>"` into `buf` via `std.fmt.bufPrint`.
/// Returns a slice of `buf` — no heap allocation.
pub fn formatAttachAppIdFlag(buf: []u8, pane: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "--app-id={s}{s}", .{ attach_app_id_prefix, pane });
}

/// Returns the exact 11-element argv for `omarchy launch or focus tui … herdr
/// agent attach <pane> --takeover`.  Pure — no process spawn, no GTK.
pub fn buildAttachArgv(app_id_flag: []const u8, pane: []const u8) [11][]const u8 {
    return .{
        "omarchy",
        "launch",
        "or",
        "focus",
        "tui",
        app_id_flag,
        "herdr",
        "agent",
        "attach",
        pane,
        "--takeover",
    };
}

// ---------------------------------------------------------------------------
// Spawn
// ---------------------------------------------------------------------------

/// Spawns `omarchy launch or focus tui … herdr agent attach <pane> --takeover`
/// as an unowned orphan (same pattern as `LocalServer.spawnHerdrServer`).
/// The returned `Child` is discarded — the process is not reaped.
pub fn spawnAttach(io: Io, environ: Environ.Map, pane: []const u8) !void {
    var buf: [256]u8 = undefined;
    const app_id_flag = try formatAttachAppIdFlag(&buf, pane);
    const argv = buildAttachArgv(app_id_flag, pane);
    _ = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &environ,
    });
    // Child is discarded — unowned orphan, never waited/killed.
}

// ---------------------------------------------------------------------------
// Compat guard + spawn
// ---------------------------------------------------------------------------

/// Reads `herdr status --json` via `LocalServer.readHerdrStatus`.  If the
/// server reports `compatible == false`, logs the mismatch and does NOT open a
/// window.  In any other case (compatible, or null because the status could not
/// be read), spawns the attach.  Errors from `spawnAttach` are logged, never
/// propagated — this function runs from a detached thread.
pub fn attachOrLogMismatch(io: Io, gpa: std.mem.Allocator, environ: Environ.Map, pane: []const u8) void {
    if (LocalServer.readHerdrStatus(io, gpa, environ)) |compat| {
        if (!compat.compatible) {
            std.log.err("attach: protocol mismatch for pane {s} (restart_needed={any}), not opening window", .{ pane, compat.restart_needed });
            return;
        }
    }
    spawnAttach(io, environ, pane) catch |err| {
        std.log.err("attach: spawn failed for pane {s}: {any}", .{ pane, err });
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "formatAttachAppIdFlag: exact output for pane p1" {
    var buf: [256]u8 = undefined;
    const result = try formatAttachAppIdFlag(&buf, "p1");
    try testing.expectEqualStrings("--app-id=io.github.alejodelosrios.kelpie.attach.p1", result);
}

test "buildAttachArgv: exact 11-element array in order" {
    const flag = "--app-id=io.github.alejodelosrios.kelpie.attach.p1";
    const argv = buildAttachArgv(flag, "p1");
    try testing.expectEqualStrings("omarchy", argv[0]);
    try testing.expectEqualStrings("launch", argv[1]);
    try testing.expectEqualStrings("or", argv[2]);
    try testing.expectEqualStrings("focus", argv[3]);
    try testing.expectEqualStrings("tui", argv[4]);
    try testing.expectEqualStrings("--app-id=io.github.alejodelosrios.kelpie.attach.p1", argv[5]);
    try testing.expectEqualStrings("herdr", argv[6]);
    try testing.expectEqualStrings("agent", argv[7]);
    try testing.expectEqualStrings("attach", argv[8]);
    try testing.expectEqualStrings("p1", argv[9]);
    try testing.expectEqualStrings("--takeover", argv[10]);
}

test "formatAttachAppIdFlag: empty pane still produces a valid flag" {
    var buf: [256]u8 = undefined;
    const result = try formatAttachAppIdFlag(&buf, "");
    try testing.expectEqualStrings("--app-id=io.github.alejodelosrios.kelpie.attach.", result);
}

test "buildAttachArgv: empty pane is passed through as-is (not our job to validate)" {
    const flag = "--app-id=io.github.alejodelosrios.kelpie.attach.";
    const argv = buildAttachArgv(flag, "");
    try testing.expectEqualStrings("", argv[9]);
}

// `spawnAttach` uses a 256-byte stack buffer for the `--app-id=` flag
// (prefix "io.github.alejodelosrios.kelpie.attach." is 39 bytes + 9 for
// "--app-id=" = 48 bytes of fixed overhead). A `pane` longer than 208 bytes
// overflows that buffer. `pane` is a herdr-assigned identifier, not user
// input (see design's "Riesgos y preguntas abiertas"), so this is a
// documented edge rather than a crash risk — but it must fail as an *error*,
// never silently truncate or panic.
test "formatAttachAppIdFlag: pane too long for a 256-byte buffer returns NoSpaceLeft, not a panic" {
    var buf: [256]u8 = undefined;
    const long_pane = "p" ** 209; // 48 (fixed overhead) + 209 > 256
    try testing.expectError(error.NoSpaceLeft, formatAttachAppIdFlag(&buf, long_pane));
}

test "formatAttachAppIdFlag: pane exactly at the 256-byte boundary still fits" {
    var buf: [256]u8 = undefined;
    const boundary_pane = "p" ** 208; // 48 + 208 == 256, exact fit
    const result = try formatAttachAppIdFlag(&buf, boundary_pane);
    try testing.expectEqual(@as(usize, 256), result.len);
}
