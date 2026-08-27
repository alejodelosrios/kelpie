const std = @import("std");

pub const name = "kelpie";
// ponytail: duplicated from build.zig.zon on purpose; wire a build option when the version is set by CI.
pub const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    var buf: [128]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try stdout.interface.print("{s} {s}\n", .{ name, version });
    try stdout.interface.flush();
}

test "version is valid semver" {
    _ = try std.SemanticVersion.parse(version);
}
