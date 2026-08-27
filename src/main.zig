const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const herdr_probe = @import("herdr/probe.zig");

pub const name = "kelpie";
// ponytail: duplicated from build.zig.zon on purpose; wire a build option when the version is set by CI.
pub const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var vt_info = false;
    var herdr_probe_flag = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--vt-info")) vt_info = true;
        if (std.mem.eql(u8, arg, "--herdr-probe")) herdr_probe_flag = true;
    }

    if (herdr_probe_flag) {
        if (init.environ_map.get("HERDR_ENV") == null) {
            try stdout.interface.print("error: --herdr-probe requires HERDR_ENV=1 (must run inside a herdr session)\n", .{});
            try stdout.interface.flush();
            return;
        }
        return herdr_probe.run(init);
    }

    if (vt_info) {
        var t: ghostty_vt.Terminal = try .init(init.io, init.gpa, .{
            .cols = 80,
            .rows = 24,
        });
        defer t.deinit(init.gpa);
        try stdout.interface.print("{d}x{d}\n", .{ t.cols, t.rows });
    } else {
        try stdout.interface.print("{s} {s}\n", .{ name, version });
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
}
