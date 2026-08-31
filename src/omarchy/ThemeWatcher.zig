//! Generic directory watcher for the `area:omarchy` family (#15, and later #18/#42/#43/#46).
//! Watches a directory with a `GFileMonitor` (not a single file) because
//! `omarchy-theme-set` replaces the whole `current/theme` directory with
//! `rm -rf` + `mv` (`/usr/share/omarchy/bin/omarchy-theme-set:291-293`) — a
//! watch on the file's inode would go orphaned on the first theme change.
//! See roadmap/designs/15-theme-watcher.md for the full spec and citation table.
const std = @import("std");
const gobject = @import("gobject");
const glib = @import("glib");
const gio = @import("gio");

const ThemeWatcher = @This();

/// Debounce window: a burst of directory events (rm -rf + mv + echo from a
/// single `omarchy-theme-set` run) collapses into one `on_reload` call.
const debounce_ms: c_uint = 100;

monitor: ?*gio.FileMonitor = null,
/// true while `monitor` is watching the parent of `dir_path` (because
/// `dir_path` didn't exist yet) instead of `dir_path` itself.
watching_ancestor: bool = false,

dir_path_buf: [std.fs.max_path_bytes:0]u8 = undefined,
dir_path: [:0]const u8 = "",
dir_basename_buf: [std.fs.max_name_bytes]u8 = undefined,
dir_basename: []const u8 = "",

on_reload: ?*const fn (?*anyopaque) void = null,
user_data: ?*anyopaque = null,

debounce_id: c_uint = 0,

/// Arms the watcher on `dir_path`. A later call cancels whatever monitor is
/// currently active before arming a new one — only one `GFileMonitor` is
/// ever alive at a time (criterio de aceptación 3 del issue #15).
pub fn start(
    self: *ThemeWatcher,
    dir_path: []const u8,
    on_reload: *const fn (?*anyopaque) void,
    user_data: ?*anyopaque,
) void {
    self.deinit();

    self.dir_path = std.fmt.bufPrintZ(&self.dir_path_buf, "{s}", .{dir_path}) catch {
        std.log.warn("ThemeWatcher: path too long ({d} bytes): {s}", .{ dir_path.len, dir_path });
        return;
    };
    const basename = std.fs.path.basename(self.dir_path);
    if (basename.len > self.dir_basename_buf.len) {
        std.log.warn("ThemeWatcher: dir basename too long ({d} bytes): {s}", .{ basename.len, basename });
        return;
    }
    @memcpy(self.dir_basename_buf[0..basename.len], basename);
    self.dir_basename = self.dir_basename_buf[0..basename.len];

    self.on_reload = on_reload;
    self.user_data = user_data;

    self.armDirectoryOrAncestor();
}

/// Cancels the active monitor (if any) and the pending debounce timer.
pub fn deinit(self: *ThemeWatcher) void {
    self.cancelMonitor();
    if (self.debounce_id != 0) {
        _ = glib.Source.remove(self.debounce_id);
        self.debounce_id = 0;
    }
}

fn cancelMonitor(self: *ThemeWatcher) void {
    if (self.monitor) |m| {
        _ = gio.FileMonitor.cancel(m);
        gobject.Object.unref(gobject.ext.as(gobject.Object, m));
        self.monitor = null;
    }
}

/// If `self.dir_path` exists, watches it directly. Otherwise watches its
/// parent (one level only — see design "Riesgos") for the `created`/
/// `moved_in` event that announces `dir_path` itself, and re-arms on it.
fn armDirectoryOrAncestor(self: *ThemeWatcher) void {
    const dir_file = gio.File.newForPath(self.dir_path);
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, dir_file));

    if (gio.File.queryExists(dir_file, null) != 0) {
        self.watching_ancestor = false;
        self.armMonitorOn(dir_file, self.dir_path);
        return;
    }

    std.log.warn("ThemeWatcher: {s} does not exist yet, watching its parent", .{self.dir_path});

    const parent = std.fs.path.dirname(self.dir_path) orelse {
        std.log.warn("ThemeWatcher: {s} has no parent, giving up", .{self.dir_path});
        return;
    };
    var parent_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const parent_z = std.fmt.bufPrintZ(&parent_buf, "{s}", .{parent}) catch {
        std.log.warn("ThemeWatcher: parent path too long: {s}", .{parent});
        return;
    };
    const parent_file = gio.File.newForPath(parent_z);
    defer gobject.Object.unref(gobject.ext.as(gobject.Object, parent_file));

    if (gio.File.queryExists(parent_file, null) == 0) {
        std.log.warn("ThemeWatcher: ancestor {s} doesn't exist either, no monitor active until next start()", .{parent_z});
        return;
    }

    self.watching_ancestor = true;
    self.armMonitorOn(parent_file, parent_z);
}

fn armMonitorOn(self: *ThemeWatcher, file: *gio.File, path_for_log: []const u8) void {
    var err: ?*glib.Error = null;
    const m = gio.File.monitorDirectory(file, .flags_watch_moves, null, &err);
    if (m) |monitor| {
        self.monitor = monitor;
        _ = gio.FileMonitor.signals.changed.connect(monitor, *ThemeWatcher, &onFileMonitorChanged, self, .{});
    } else {
        if (err) |e| {
            std.log.warn("ThemeWatcher: monitorDirectory({s}) failed: {s}", .{ path_for_log, e.f_message orelse "unknown error" });
            glib.Error.free(e);
        } else {
            std.log.warn("ThemeWatcher: monitorDirectory({s}) failed", .{path_for_log});
        }
    }
}

fn onFileMonitorChanged(
    _: *gio.FileMonitor,
    file: *gio.File,
    _: ?*gio.File,
    event_type: gio.FileMonitorEvent,
    self: *ThemeWatcher,
) callconv(.c) void {
    const basename = gio.File.getBasename(file) orelse return;
    defer glib.free(basename);
    const name = std.mem.span(basename);

    if (self.watching_ancestor) {
        // Waiting for dir_path's own basename to appear as a child of the
        // ancestor we're watching — then cancel this monitor and re-arm on
        // the real directory, without restarting the process.
        if (!std.mem.eql(u8, name, self.dir_basename)) return;
        if (event_type != .created and event_type != .moved_in) return;
        self.cancelMonitor();
        self.armDirectoryOrAncestor();
        // Catch-up reload: anything created inside dir_path between this
        // event and armMonitorOn() finishing above (e.g. `current/theme/`
        // appearing right after `current/` itself) has no monitor watching
        // it and would otherwise be silently missed — see auditor bloqueante
        // 2 on #15. Fire the debounce unconditionally so that window is
        // covered even without a further fs event.
        if (self.debounce_id != 0) {
            _ = glib.Source.remove(self.debounce_id);
        }
        self.debounce_id = glib.timeoutAddOnce(debounce_ms, &onDebounceFire, self);
        return;
    }

    // `omarchy-theme-set` does `rm -rf current/theme && mv current/next-theme
    // current/theme` (/usr/share/omarchy/bin/omarchy-theme-set:291-293) — an
    // intra-directory rename. With WATCH_MOVES that arrives as a single
    // `.renamed` event whose `file` basename is the OLD name ("next-theme"),
    // not "theme" (gio2.zig:8450-8452: "For renames, file will be the old
    // name and other_file is the new name"). So a rename can never match the
    // `name == "theme"` check below — any rename inside the watched
    // directory is a theme swap regardless of its old name.
    const relevant = event_type == .renamed or
        (std.mem.eql(u8, name, "theme") and
            (event_type == .moved_in or event_type == .created or event_type == .deleted)) or
        (std.mem.eql(u8, name, "theme.name") and event_type == .changed);
    if (!relevant) return;

    if (self.debounce_id != 0) {
        _ = glib.Source.remove(self.debounce_id);
    }
    self.debounce_id = glib.timeoutAddOnce(debounce_ms, &onDebounceFire, self);
}

fn onDebounceFire(data: ?*anyopaque) callconv(.c) void {
    const self: *ThemeWatcher = @ptrCast(@alignCast(data.?));
    self.debounce_id = 0;
    if (self.on_reload) |cb| cb(self.user_data);
}

// --- tests ---

/// Pumps the default GLib main context for `steps` iterations, each one
/// bounded to ~20ms by a throwaway watchdog timeout so a missing event can
/// never hang the test — only make it fail slowly. Leftover watchdogs that
/// fire after the loop already returned are harmless (they call a no-op).
fn pumpMainLoop(steps: u32) void {
    var i: u32 = 0;
    while (i < steps) : (i += 1) {
        _ = glib.timeoutAddOnce(20, &pumpWatchdogFire, null);
        _ = glib.MainContext.iteration(null, 1);
    }
}

fn pumpWatchdogFire(_: ?*anyopaque) callconv(.c) void {}

/// Pumps the default GLib main context until `counter.* >= min_value` or
/// `deadline_ms` of real wall-clock time have elapsed, whichever comes
/// first. Unlike a fixed iteration count, this bounds real time: measured
/// (not assumed) — `g_main_context_iteration` returns as soon as ANY source
/// is ready, so N iterations don't guarantee N*20ms actually passed, which
/// made the criterio-4 test intermittent (~1/3 runs). Pass
/// `std.math.maxInt(u32)` as `min_value` to just pump for `deadline_ms`
/// regardless of the counter (a settle window).
fn pumpUntil(counter: *const u32, min_value: u32, deadline_ms: u64) void {
    const io = std.testing.io;
    const started_at = std.Io.Clock.Timestamp.now(io, .awake);
    const deadline_ns: i96 = @as(i96, @intCast(deadline_ms)) * std.time.ns_per_ms;
    while (counter.* < min_value and started_at.untilNow(io).raw.nanoseconds < deadline_ns) {
        _ = glib.timeoutAddOnce(20, &pumpWatchdogFire, null);
        _ = glib.MainContext.iteration(null, 1);
    }
}

var test_watcher_next_id = std.atomic.Value(u32).init(0);

fn testBasePath(buf: *[64]u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "/tmp/kelpie-tw-{d}-{d}",
        .{ std.posix.system.getpid(), test_watcher_next_id.fetchAdd(1, .monotonic) },
    );
}

fn onTestReload(data: ?*anyopaque) void {
    const counter: *u32 = @ptrCast(@alignCast(data.?));
    counter.* += 1;
}

test "ThemeWatcher: rm -rf + mv + write theme.name three times in a row produces reloads with fresh content" {
    const io = std.testing.io;
    var base_buf: [64]u8 = undefined;
    const base = try testBasePath(&base_buf);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var path_buf: [128]u8 = undefined;
    const current = try std.fmt.bufPrint(&path_buf, "{s}/current", .{base});
    try std.Io.Dir.cwd().createDirPath(io, current);

    var theme_buf: [128]u8 = undefined;
    const theme_dir = try std.fmt.bufPrint(&theme_buf, "{s}/theme", .{current});
    try std.Io.Dir.cwd().createDirPath(io, theme_dir);
    var css_buf: [160]u8 = undefined;
    const css_path = try std.fmt.bufPrint(&css_buf, "{s}/kelpie.css", .{theme_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = css_path, .data = "/* v0 */" });
    var name_buf: [160]u8 = undefined;
    const name_path = try std.fmt.bufPrint(&name_buf, "{s}/theme.name", .{current});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name_path, .data = "v0" });

    var watcher: ThemeWatcher = .{};
    defer watcher.deinit();
    var reload_count: u32 = 0;
    watcher.start(current, &onTestReload, &reload_count);

    var next_buf: [128]u8 = undefined;
    const next_theme_dir = try std.fmt.bufPrint(&next_buf, "{s}/next-theme", .{current});
    var next_css_buf: [160]u8 = undefined;
    const next_css_path = try std.fmt.bufPrint(&next_css_buf, "{s}/kelpie.css", .{next_theme_dir});

    var cycle: u8 = 0;
    while (cycle < 3) : (cycle += 1) {
        var content_buf: [16]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "/* v{d} */", .{cycle + 1});

        try std.Io.Dir.cwd().deleteTree(io, theme_dir);
        pumpMainLoop(5);

        try std.Io.Dir.cwd().createDirPath(io, next_theme_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = next_css_path, .data = content });
        try std.Io.Dir.renameAbsolute(next_theme_dir, theme_dir, io);
        pumpMainLoop(5);

        var name_content_buf: [16]u8 = undefined;
        const name_content = try std.fmt.bufPrint(&name_content_buf, "v{d}", .{cycle + 1});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name_path, .data = name_content });

        // Let the 100ms debounce settle before starting the next cycle, so
        // this measures whether a whole rm+mv+echo burst collapses into one
        // reload (design's open risk) — see the comment on the assertion below.
        pumpUntil(&reload_count, std.math.maxInt(u32), 150);
    }

    // Measured (not assumed) behavior: the debounce is per-event, not
    // per-burst — see ThemeWatcher.onFileMonitorChanged. Empirically the 3
    // Measured (not assumed): in local runs this produced 5 reloads for the
    // 3 cycles above (never fewer than 3) — the debounce is per-event, not
    // per-burst (see onFileMonitorChanged: each relevant event resets the
    // single 100ms timer), so a cycle's rm/mv/echo only collapses into one
    // reload when all three land inside the same 100ms window; otherwise a
    // cycle produces more than one. The exact count is timing-sensitive, so
    // assert the design's required floor (3) plus the content check, not an
    // exact number.
    try std.testing.expect(reload_count >= 3);

    var read_buf: [64]u8 = undefined;
    const read_css = try std.Io.Dir.cwd().readFile(io, css_path, &read_buf);
    try std.testing.expectEqualStrings("/* v3 */", read_css);

    // Concern 3 (auditor, #15): the three cycles above pass even without the
    // bloqueante-1 fix, because a real "rm -rf theme" always fires its own
    // `.deleted` on basename "theme" (already relevant pre-fix) before the
    // `mv` even happens — so a rm+mv+echo cycle reloads regardless of
    // whether `.renamed` is recognized, and doesn't isolate the fix. To
    // isolate the rename path with zero confounding `.deleted`/`.created`
    // events, rename "theme" itself AWAY (no delete, no echo): the fired
    // event is `.renamed` whose `file` basename is "theme" (the OLD name,
    // per gio2.zig:8450-8452) — which the `name == "theme"` branch below
    // explicitly excludes (.renamed isn't in {moved_in, created, deleted}),
    // so pre-fix this produces no reload at all. Verified by hand: reverting
    // the `event_type == .renamed or` clause to `false and event_type ==
    // .renamed or` makes this assertion fail while the three-cycle floor
    // above still passes.
    var away_buf: [128]u8 = undefined;
    const theme_away_dir = try std.fmt.bufPrint(&away_buf, "{s}/theme-away", .{current});
    const count_before_rename_only = reload_count;
    try std.Io.Dir.renameAbsolute(theme_dir, theme_away_dir, io);
    pumpUntil(&reload_count, count_before_rename_only + 1, 500);
    try std.testing.expect(reload_count > count_before_rename_only);
}

test "ThemeWatcher: current/ absent at start does not crash, engages once created, and keeps reloading" {
    const io = std.testing.io;
    var base_buf: [64]u8 = undefined;
    const base = try testBasePath(&base_buf);
    try std.Io.Dir.cwd().createDirPath(io, base); // ancestor exists, "current/" doesn't
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    var path_buf: [128]u8 = undefined;
    const current = try std.fmt.bufPrint(&path_buf, "{s}/current", .{base});

    var watcher: ThemeWatcher = .{};
    defer watcher.deinit();
    var reload_count: u32 = 0;
    watcher.start(current, &onTestReload, &reload_count); // must not crash

    try std.Io.Dir.cwd().createDirPath(io, current);
    // ancestor monitor sees "current" created, re-arms on it. Deadline-based,
    // not a fixed iteration count: g_main_context_iteration returns as soon
    // as any source is ready, so a fixed count doesn't bound real wall-clock
    // time — this made the test intermittent (~1/3 runs).
    pumpUntil(&reload_count, 1, 2000); // satisfied by the catch-up reload alone
    pumpUntil(&reload_count, std.math.maxInt(u32), 150); // let the debounce settle
    const after_engage = reload_count;

    // Auditor #15 (2nd DENEGADO): the catch-up reload above already pushes
    // reload_count to >= 1 by itself, so asserting `>= 1` here would pass
    // even if the re-arm onto the real directory never happened — this test
    // must prove the re-arm keeps reloading, not just that engaging produced
    // one reload. Snapshot after the catch-up settles, then require a
    // strictly later reload from content created after re-arm.
    var theme_buf: [128]u8 = undefined;
    const theme_dir = try std.fmt.bufPrint(&theme_buf, "{s}/theme", .{current});
    try std.Io.Dir.cwd().createDirPath(io, theme_dir);
    var css_buf: [160]u8 = undefined;
    const css_path = try std.fmt.bufPrint(&css_buf, "{s}/kelpie.css", .{theme_dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = css_path, .data = "/* v1 */" });
    pumpUntil(&reload_count, after_engage + 1, 2000);

    try std.testing.expect(reload_count > after_engage);
}
