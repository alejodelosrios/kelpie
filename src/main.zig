const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub const name = "kelpie";
// ponytail: duplicated from build.zig.zon on purpose; wire a build option when the version is set by CI.
pub const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var vt_info = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--vt-info")) vt_info = true;
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
