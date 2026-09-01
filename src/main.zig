const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const herdr_probe = @import("herdr/probe.zig");
const spike_b = @import("ui/spike_b.zig");
const app_shell = @import("ui/app_shell.zig");
const sidebar = @import("ui/sidebar.zig");
const herdr_link = @import("ui/herdr_link.zig");

pub const name = "kelpie";
// ponytail: duplicated from build.zig.zon on purpose; wire a build option when the version is set by CI.
pub const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Local dispatch: subcommands that must never travel over D-Bus or touch
    // GApplication. Checked before the flag loop so they work without a session bus.
    if (args.len >= 2) {
        const subcmd = args[1];
        if (std.mem.eql(u8, subcmd, "setup")) {
            // ponytail: stub — setup feature not yet implemented (future issue).
            try stdout.interface.print("setup: not yet implemented\n", .{});
            try stdout.interface.flush();
            return;
        }
        if (std.mem.eql(u8, subcmd, "askpass")) {
            // ponytail: stub — askpass feature not yet implemented (future issue).
            try stdout.interface.print("askpass: not yet implemented\n", .{});
            try stdout.interface.flush();
            return;
        }
    }

    var vt_info = false;
    var herdr_probe_flag = false;
    var run_spike_b = false;
    var version_flag = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--vt-info")) vt_info = true;
        if (std.mem.eql(u8, arg, "--herdr-probe")) herdr_probe_flag = true;
        if (std.mem.eql(u8, arg, "--spike-b")) run_spike_b = true;
        if (std.mem.eql(u8, arg, "--version")) version_flag = true;
        if (std.mem.eql(u8, arg, "--demo-sidebar")) {
            app_shell.demo_sidebar_n = 4;
        } else if (std.mem.startsWith(u8, arg, "--demo-sidebar=")) {
            const n_str = arg["--demo-sidebar=".len..];
            app_shell.demo_sidebar_n = std.fmt.parseInt(u32, n_str, 10) catch 4;
        }
    }

    if (version_flag) {
        try stdout.interface.print("{s} {s}\n", .{ name, version });
        try stdout.interface.flush();
        return;
    } else if (herdr_probe_flag) {
        if (init.environ_map.get("HERDR_ENV") == null) {
            try stdout.interface.print("error: --herdr-probe requires HERDR_ENV=1 (must run inside a herdr session)\n", .{});
            try stdout.interface.flush();
            return;
        }
        return herdr_probe.run(init);
    } else if (run_spike_b) {
        return spike_b.run();
    } else if (vt_info) {
        var t: ghostty_vt.Terminal = try .init(init.io, init.gpa, .{
            .cols = 80,
            .rows = 24,
        });
        defer t.deinit(init.gpa);
        try stdout.interface.print("{d}x{d}\n", .{ t.cols, t.rows });
    } else {
        std.process.exit(app_shell.run(init));
    }
    try stdout.interface.flush();
}

test "terminal init/deinit no leak" {
    var t: ghostty_vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 80), t.cols);
    try std.testing.expectEqual(@as(u16, 24), t.rows);
}

test "terminal dimensions come from Options, not a hardcoded 80x24" {
    var t: ghostty_vt.Terminal = try .init(std.testing.io, std.testing.allocator, .{
        .cols = 40,
        .rows = 12,
    });
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 40), t.cols);
    try std.testing.expectEqual(@as(u16, 12), t.rows);
}

test "version is valid semver" {
    _ = try std.SemanticVersion.parse(version);
}

// Zig's test runner only discovers `test` blocks in the root source file
// plus whatever a `test {}` block explicitly references — it does not walk
// `@import`s transitively (verified against zig 0.16.0). Without this,
// herdr/probe.zig's and herdr/client.zig's tests would silently never run
// under `zig build test`.
test {
    _ = herdr_probe;
    _ = app_shell;
    _ = sidebar;
    _ = herdr_link;
    // Store (#12) ya no tiene módulo de test propio: su consumidor real (el
    // sidebar de #16) vive en el exe, así que sus tests corren aquí.
    _ = @import("model/Store.zig");
}
