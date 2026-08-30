const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ghostty-vt: lazy dependency — only downloaded when actually needed.
    if (b.lazyDependency("ghostty", .{})) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    // gobject: GTK4/libadwaita/Pango bindings for --spike-b, same lazy dependency and
    // module mapping as Ghostty's apprt/gtk (SharedDeps.zig:713-731), plus the
    // pango/pangocairo/cairo/gsk/graphene/gdkwayland modules this spike needs directly.
    if (b.lazyDependency("gobject", .{ .target = target, .optimize = optimize })) |gobject| {
        const gobject_imports = .{
            .{ "adw", "adw1" },
            .{ "gdk", "gdk4" },
            .{ "gdkwayland", "gdkwayland4" },
            .{ "gio", "gio2" },
            .{ "glib", "glib2" },
            .{ "glibunix", "glibunix2" },
            .{ "gobject", "gobject2" },
            .{ "gtk", "gtk4" },
            .{ "gsk", "gsk4" },
            .{ "graphene", "graphene1" },
            .{ "pango", "pango1" },
            .{ "pangocairo", "pangocairo1" },
            .{ "cairo", "cairo1" },
            .{ "xlib", "xlib2" },
        };
        inline for (gobject_imports) |import| {
            const name, const module = import;
            exe_mod.addImport(name, gobject.module(module));
        }
    }

    // kelpie.css fallback (#14): embedded data, not code — the only place hex colors
    // are allowed (ADR-0001 §5). Lives in data/ so `grep src/` for hex stays clean.
    exe_mod.addAnonymousImport("kelpie-fallback-css", .{ .root_source_file = b.path("data/kelpie-fallback.css") });

    const exe = b.addExecutable(.{
        .name = "kelpie",
        .root_module = exe_mod,
    });
    // libGL: plan-B GtkGLArea render callback calls glClearColor/glClear directly (no
    // gobject binding for raw GL) — system library, not a new zig-pkg dependency.
    exe_mod.linkSystemLibrary("GL", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run kelpie").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Spike C (#4): vive fuera de main.zig porque no es parte del binario, solo
    // un test que ejerce Terminal + RenderState. Mismo import de ghostty-vt.
    const vt_spike_mod = b.createModule(.{
        .root_source_file = b.path("src/vt_spike.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (b.lazyDependency("ghostty", .{})) |dep| {
        vt_spike_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    const vt_spike_tests = b.addTest(.{ .root_module = vt_spike_mod });
    test_step.dependOn(&b.addRunArtifact(vt_spike_tests).step);

    // theme_css (#14): no lo importa nadie todavía (su consumidor es #26), así que
    // sin esto zig build test nunca compila ni corre sus tests. Mismo patrón que
    // vt_spike_mod — módulo propio, sin dependencias más allá de std.
    const theme_css_mod = b.createModule(.{
        .root_source_file = b.path("src/ui/theme_css.zig"),
        .target = target,
        .optimize = optimize,
    });
    const theme_css_tests = b.addTest(.{ .root_module = theme_css_mod });
    test_step.dependOn(&b.addRunArtifact(theme_css_tests).step);

    // LocalServer (#11): no lo importa nadie todavía (su consumidor es #17), así que
    // sin esto zig build test nunca compila ni corre sus tests. Mismo patrón que
    // theme_css_mod — módulo propio, sin dependencias más allá de std.
    const local_server_mod = b.createModule(.{
        .root_source_file = b.path("src/herdr/LocalServer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const local_server_tests = b.addTest(.{ .root_module = local_server_mod });
    test_step.dependOn(&b.addRunArtifact(local_server_tests).step);

    // Events (#10): no lo importa nadie todavía (su consumidor es un issue de UI
    // posterior), así que sin esto zig build test nunca compila ni corre sus tests.
    // Mismo patrón que theme_css_mod — módulo propio, sin dependencias más allá de std.
    const events_mod = b.createModule(.{
        .root_source_file = b.path("src/herdr/Events.zig"),
        .target = target,
        .optimize = optimize,
    });
    const events_tests = b.addTest(.{ .root_module = events_mod });
    test_step.dependOn(&b.addRunArtifact(events_tests).step);
}
