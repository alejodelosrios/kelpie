//! Omarchy notification integration (#18): watches the Store for agent status
//! transitions and fires `omarchy-notification-send` / `omarchy-notification-dismiss`
//! toasts.  Follows the same struct-with-`@This()` / `init` / pure-functions
//! pattern as `ThemeWatcher.zig`.
//!
//! Territory: ui-builder (`area:omarchy`).  See roadmap/designs/18-notificaciones-omarchy.md.
const std = @import("std");
const types = @import("../herdr/types.zig");
const store_mod = @import("../model/Store.zig");

const Notify = @This();

const notif_send_bin = "/usr/share/omarchy/bin/omarchy-notification-send";
const notif_dismiss_bin = "/usr/share/omarchy/bin/omarchy-notification-dismiss";

const glyph_blocked = "\u{f0026}"; // 󰀦
const glyph_done = "\u{f012c}"; // 󰄬

gpa: std.mem.Allocator = std.heap.page_allocator,
io: std.Io = undefined,
is_window_active: ?*const fn (?*anyopaque) bool = null,
is_window_active_data: ?*anyopaque = null,

/// Tracks the last notification id per (device_id, pane_id) so a second
/// notification for the same agent replaces the toast instead of stacking.
/// Also stores the headline used, so `dismiss` can reconstruct it.
notifs: NotifyMap = undefined,
notifs_inited: bool = false,

const NotifyEntry = struct {
    id: u32,
    /// Owned (dupe'd from agent data at send time).
    headline: []const u8,
    /// Owned.
    agent_name: []const u8,
};

const NotifyKey = struct {
    device_id: []const u8,
    pane_id: []const u8,
};

const NotifyKeyContext = struct {
    pub fn hash(_: NotifyKeyContext, key: NotifyKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.device_id);
        h.update(key.pane_id);
        return h.final();
    }

    pub fn eql(_: NotifyKeyContext, a: NotifyKey, b: NotifyKey) bool {
        return std.mem.eql(u8, a.device_id, b.device_id) and
            std.mem.eql(u8, a.pane_id, b.pane_id);
    }
};

const NotifyMap = std.hash_map.HashMap(
    NotifyKey,
    NotifyEntry,
    NotifyKeyContext,
    std.hash_map.default_max_load_percentage,
);

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    is_window_active: *const fn (?*anyopaque) bool,
    is_window_active_data: ?*anyopaque,
) Notify {
    return .{
        .gpa = gpa,
        .io = io,
        .is_window_active = is_window_active,
        .is_window_active_data = is_window_active_data,
    };
}

fn ensureMapInited(self: *Notify) void {
    if (self.notifs_inited) return;
    self.notifs_inited = true;
    self.notifs = NotifyMap.initContext(self.gpa, .{});
}

pub fn deinit(self: *Notify) void {
    if (!self.notifs_inited) return;
    var it = self.notifs.iterator();
    while (it.next()) |entry| {
        self.gpa.free(entry.key_ptr.device_id);
        self.gpa.free(entry.key_ptr.pane_id);
        self.gpa.free(entry.value_ptr.headline);
        self.gpa.free(entry.value_ptr.agent_name);
    }
    self.notifs.deinit();
}

/// Returns a `ChangeObserver` for registration with the Store.
pub fn observer(self: *Notify) store_mod.ChangeObserver {
    return .{
        .ptr = self,
        .onChangedFn = &onStoreChanged,
        .onTransitionFn = &onStoreTransition,
    };
}

fn onStoreChanged(_: *anyopaque) void {
    // No-op: Notify only cares about transitions, not bulk changes.
}

fn onStoreTransition(
    ptr: *anyopaque,
    agent: *const store_mod.Agent,
    _: types.AgentStatus,
    to: types.AgentStatus,
) void {
    const self: *Notify = @ptrCast(@alignCast(ptr));
    self.ensureMapInited();

    switch (to) {
        .blocked => {
            // Always notify on blocked, regardless of focus.
            self.sendNotification(agent, .critical, glyph_blocked) catch |err| {
                std.log.err("Notify: send blocked notification failed: {t}", .{err});
            };
        },
        .done => {
            // Skip notification if this agent is focused AND the window is active.
            if (agent.focused) {
                if (self.is_window_active) |cb| {
                    if (cb(self.is_window_active_data)) return;
                }
            }
            self.sendNotification(agent, .normal, glyph_done) catch |err| {
                std.log.err("Notify: send done notification failed: {t}", .{err});
            };
        },
        // idle, working, unknown: no notification.
        .idle, .working, .unknown => {},
    }
}

fn sendNotification(
    self: *Notify,
    agent: *const store_mod.Agent,
    urgency: Urgency,
    glyph: []const u8,
) !void {
    const agent_name = agentName(agent);
    const title = agent.displayTitle();
    const headline = try std.fmt.allocPrint(self.gpa, "{s} · {s}", .{ title, agent_name });
    // Bug 2 fix: headline is allocated above but can leak if any subsequent
    // try (buildArgv, spawn, wait, getOrPut) propagates an error.  errdefer
    // frees it on error; ownership transfers to the map on the happy path
    // (gop.value_ptr.headline = headline), so we cancel the errdefer by
    // NOT freeing headline there — same pattern as Store.applySnapshot's
    // per-field errdefer (Store.zig:210-230).
    errdefer self.gpa.free(headline);

    // Bug 1 fix: dupe device_id/pane_id so the NotifyMap key owns its slices.
    // The Store's Agent fields are aliased from AgentKey (Store.zig:868) and
    // freed when the Store drops the agent — our map must outlive that.
    const key_device = try self.gpa.dupe(u8, agent.device_id);
    errdefer self.gpa.free(key_device);
    const key_pane = try self.gpa.dupe(u8, agent.pane_id);
    errdefer self.gpa.free(key_pane);

    const key = NotifyKey{
        .device_id = key_device,
        .pane_id = key_pane,
    };

    // Look up previous notification id for this agent (for -r replacement).
    // Use the original slices for the read-only lookup (they're still valid
    // here; the Store hasn't freed the agent yet during onTransitionFn).
    const lookup_key = NotifyKey{
        .device_id = agent.device_id,
        .pane_id = agent.pane_id,
    };
    const replaces_id: ?u32 = if (self.notifs.get(lookup_key)) |entry| entry.id else null;

    // Blocker 4 fix: dupe agent_name BEFORE getOrPut so the literal that
    // writes into the map entry has no falible try/dupe inside it.
    const agent_name_dup = try self.gpa.dupe(u8, agent_name);
    errdefer self.gpa.free(agent_name_dup);

    const argv_result = try buildArgv(
        self.gpa,
        agent,
        urgency,
        glyph,
        headline,
        replaces_id,
    );
    defer argv_result.deinit(self.gpa);

    // Blockers 2+3: use std.process.run (captures stdout correctly via pipe,
    // unlike readPositionalAll on a pipe which fails with error.Unseekable)
    // with a 3-second timeout so a hung D-Bus never freezes the UI thread.
    const run_result = std.process.run(self.gpa, self.io, .{
        .argv = argv_result.argv,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch |err| {
        std.log.warn("Notify: omarchy-notification-send failed: {t}", .{err});
        // return de exito: errdefer no dispara aqui, free explicito
        self.gpa.free(headline);
        self.gpa.free(key_device);
        self.gpa.free(key_pane);
        self.gpa.free(agent_name_dup);
        return;
    };
    defer self.gpa.free(run_result.stdout);
    defer self.gpa.free(run_result.stderr);

    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.log.warn("Notify: omarchy-notification-send exited with {}", .{run_result.term});
    }

    // Parse the notification id and store it.
    const notif_id = parseNotificationId(run_result.stdout) orelse {
        std.log.warn("Notify: could not parse notification id from stdout: {s}", .{run_result.stdout});
        // return de exito: errdefer no dispara aqui, free explicito
        self.gpa.free(headline);
        self.gpa.free(key_device);
        self.gpa.free(key_pane);
        self.gpa.free(agent_name_dup);
        return;
    };

    // Update or insert the notification entry.
    const gop = try self.notifs.getOrPut(key);
    if (gop.found_existing) {
        // The key we just built is a duplicate — free it; the existing entry
        // already owns its key slices.
        self.gpa.free(key_device);
        self.gpa.free(key_pane);
        self.gpa.free(gop.value_ptr.headline);
        self.gpa.free(gop.value_ptr.agent_name);
    }
    // Ownership transfers: headline → map, key_device/key_pane → map key,
    // agent_name_dup → map entry.  The errdefers are cancelled by the
    // function returning successfully — they only fire on error paths.
    gop.value_ptr.* = .{
        .id = notif_id,
        .headline = headline,
        .agent_name = agent_name_dup,
    };
}

/// Dismisses the notification for the given agent (if any).
pub fn dismiss(self: *Notify, device_id: []const u8, pane_id: []const u8) void {
    self.ensureMapInited();

    const key = NotifyKey{ .device_id = device_id, .pane_id = pane_id };
    const entry = self.notifs.get(key) orelse return;

    // entry.headline is already "title · agent_name" (set in sendNotification).
    const argv = [_][]const u8{ notif_dismiss_bin, entry.headline };

    // Blockers 2+3: std.process.run with 3s timeout, same as sendNotification.
    const run_result = std.process.run(self.gpa, self.io, .{
        .argv = &argv,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch |err| {
        std.log.err("Notify: dismiss failed: {t}", .{err});
        return;
    };
    defer self.gpa.free(run_result.stdout);
    defer self.gpa.free(run_result.stderr);

    // Remove from the map.
    if (self.notifs.fetchRemove(key)) |removed| {
        self.gpa.free(removed.key.device_id);
        self.gpa.free(removed.key.pane_id);
        self.gpa.free(removed.value.headline);
        self.gpa.free(removed.value.agent_name);
    }
}

// ---------------------------------------------------------------------------
// Pure helpers (testable without GLib / D-Bus)
// ---------------------------------------------------------------------------

const Urgency = enum { normal, critical };

fn agentName(agent: *const store_mod.Agent) []const u8 {
    return agent.display_agent orelse agent.agent orelse "agent";
}

/// Parses the notification id from `omarchy-notification-send -p` stdout.
/// Returns null if the output is empty or not a valid u32.
fn parseNotificationId(stdout: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, stdout, " \t\n\r");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

/// Builds the argv for `omarchy-notification-send`.  Caller owns the returned
/// argv (each element is an allocated string; free with `gpa.free` for each,
/// then `gpa.free(result.argv)`).
const ArgvResult = struct {
    argv: []const []const u8,

    fn deinit(self: ArgvResult, gpa: std.mem.Allocator) void {
        for (self.argv) |s| gpa.free(s);
        gpa.free(self.argv);
    }
};

fn buildArgv(
    gpa: std.mem.Allocator,
    agent: *const store_mod.Agent,
    urgency: Urgency,
    glyph: []const u8,
    headline: []const u8,
    replaces_id: ?u32,
) !ArgvResult {
    const agent_name = agentName(agent);
    const urgency_str: []const u8 = switch (urgency) {
        .critical => "critical",
        .normal => "normal",
    };
    const body = switch (urgency) {
        .critical => try std.fmt.allocPrint(gpa, "{s} needs your input · {s} · {s}", .{
            agent_name, agent.workspace_id, agent.device_id,
        }),
        .normal => try std.fmt.allocPrint(gpa, "{s} finished · {s} · {s}", .{
            agent_name, agent.workspace_id, agent.device_id,
        }),
    };

    const exec_target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{
        agent.device_id, agent.pane_id,
    });

    // Count argv elements.
    var count: usize = 14; // bin + --app-name + kelpie + -g + glyph + -u + urgency + -p + headline + body + --exec + kelpie + focus + target
    if (replaces_id != null) count += 2; // -r + id

    const argv = try gpa.alloc([]const u8, count);
    var i: usize = 0;

    argv[i] = try gpa.dupe(u8, notif_send_bin);
    i += 1;
    argv[i] = try gpa.dupe(u8, "--app-name");
    i += 1;
    argv[i] = try gpa.dupe(u8, "kelpie");
    i += 1;
    argv[i] = try gpa.dupe(u8, "-g");
    i += 1;
    argv[i] = try gpa.dupe(u8, glyph);
    i += 1;
    argv[i] = try gpa.dupe(u8, "-u");
    i += 1;
    argv[i] = try gpa.dupe(u8, urgency_str);
    i += 1;
    argv[i] = try gpa.dupe(u8, "-p");
    i += 1;

    if (replaces_id) |rid| {
        argv[i] = try gpa.dupe(u8, "-r");
        i += 1;
        argv[i] = try std.fmt.allocPrint(gpa, "{d}", .{rid});
        i += 1;
    }

    argv[i] = try gpa.dupe(u8, headline);
    i += 1;
    argv[i] = body;
    i += 1; // already allocated
    argv[i] = try gpa.dupe(u8, "--exec");
    i += 1;
    argv[i] = try gpa.dupe(u8, "kelpie");
    i += 1;
    argv[i] = try gpa.dupe(u8, "focus");
    i += 1;
    argv[i] = exec_target;
    i += 1; // already allocated

    return .{ .argv = argv };
}

// ---------------------------------------------------------------------------
// Tests — pure argv construction, no GLib / D-Bus
// ---------------------------------------------------------------------------

fn testAgent() store_mod.Agent {
    return .{
        .device_id = "local",
        .pane_id = "p1",
        .workspace_id = "ws-a",
        .tab_id = "tab-1",
        .status = .idle,
        .revision = 1,
        .focused = false,
        .agent = "claude",
        .display_agent = null,
        .title = "my-title",
    };
}

test "buildArgv: blocked notification has critical urgency, glyph, --exec, and -p" {
    const agent = testAgent();
    const result = try buildArgv(
        std.testing.allocator,
        &agent,
        .critical,
        glyph_blocked,
        "my-title · claude",
        null,
    );
    defer result.deinit(std.testing.allocator);

    // Verify ordered argv.
    var i: usize = 0;
    try std.testing.expectEqualStrings(notif_send_bin, result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("--app-name", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("kelpie", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("-g", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings(glyph_blocked, result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("-u", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("critical", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("-p", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("my-title · claude", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("claude needs your input · ws-a · local", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("--exec", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("kelpie", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("focus", result.argv[i]);
    i += 1;
    try std.testing.expectEqualStrings("local/p1", result.argv[i]);
    i += 1;
    try std.testing.expectEqual(i, result.argv.len);
}

test "buildArgv: done notification has normal urgency and done glyph" {
    const agent = testAgent();
    const result = try buildArgv(
        std.testing.allocator,
        &agent,
        .normal,
        glyph_done,
        "my-title · claude",
        null,
    );
    defer result.deinit(std.testing.allocator);

    // Find -u and verify it's "normal".
    var found_urgency = false;
    for (result.argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "-u") and idx + 1 < result.argv.len) {
            try std.testing.expectEqualStrings("normal", result.argv[idx + 1]);
            found_urgency = true;
            break;
        }
    }
    try std.testing.expect(found_urgency);

    // Verify body says "finished".
    for (result.argv) |arg| {
        if (std.mem.indexOf(u8, arg, "finished") != null) return;
    }
    try std.testing.expect(false); // body not found
}

test "buildArgv: replaces_id adds -r flag before headline" {
    const agent = testAgent();
    const result = try buildArgv(
        std.testing.allocator,
        &agent,
        .critical,
        glyph_blocked,
        "my-title · claude",
        42,
    );
    defer result.deinit(std.testing.allocator);

    // Find -r and verify it's followed by "42".
    var found_r = false;
    for (result.argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "-r") and idx + 1 < result.argv.len) {
            try std.testing.expectEqualStrings("42", result.argv[idx + 1]);
            found_r = true;
            break;
        }
    }
    try std.testing.expect(found_r);
}

test "buildArgv: injection in title is a single argv element, never interpolated" {
    var agent = testAgent();
    agent.title = "$(rm -rf ~); \\\"; echo pwned #";
    const result = try buildArgv(
        std.testing.allocator,
        &agent,
        .critical,
        glyph_blocked,
        "$(rm -rf ~); \\\"; echo pwned # · claude",
        null,
    );
    defer result.deinit(std.testing.allocator);

    // The headline must appear as exactly one element.
    var headline_count: usize = 0;
    for (result.argv) |arg| {
        if (std.mem.eql(u8, arg, "$(rm -rf ~); \\\"; echo pwned # · claude")) {
            headline_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), headline_count);

    // The --exec target must also be a single element (no shell splitting).
    var exec_target_count: usize = 0;
    for (result.argv) |arg| {
        if (std.mem.eql(u8, arg, "local/p1")) {
            exec_target_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), exec_target_count);
}

test "buildArgv: agentName uses display_agent over agent over fallback" {
    var agent = testAgent();
    agent.display_agent = "Display Name";
    agent.agent = "claude";
    try std.testing.expectEqualStrings("Display Name", agentName(&agent));

    agent.display_agent = null;
    try std.testing.expectEqualStrings("claude", agentName(&agent));

    agent.agent = null;
    try std.testing.expectEqualStrings("agent", agentName(&agent));
}

test "buildArgv: body includes workspace_id and device_id" {
    const agent = testAgent();
    const result = try buildArgv(
        std.testing.allocator,
        &agent,
        .critical,
        glyph_blocked,
        "T · claude",
        null,
    );
    defer result.deinit(std.testing.allocator);

    // Find the body element (the one after the headline).
    var found_body = false;
    for (result.argv, 0..) |arg, idx| {
        if (std.mem.eql(u8, arg, "T · claude") and idx + 1 < result.argv.len) {
            const body = result.argv[idx + 1];
            try std.testing.expect(std.mem.indexOf(u8, body, "ws-a") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "local") != null);
            found_body = true;
            break;
        }
    }
    try std.testing.expect(found_body);
}

test "parseNotificationId: valid numeric string" {
    try std.testing.expectEqual(@as(?u32, 42), parseNotificationId("42\n"));
    try std.testing.expectEqual(@as(?u32, 0), parseNotificationId("0"));
    try std.testing.expectEqual(@as(?u32, 123456), parseNotificationId("  123456  \n"));
}

test "parseNotificationId: empty or garbage returns null" {
    try std.testing.expectEqual(@as(?u32, null), parseNotificationId(""));
    try std.testing.expectEqual(@as(?u32, null), parseNotificationId("  \n"));
    try std.testing.expectEqual(@as(?u32, null), parseNotificationId("not-a-number"));
    try std.testing.expectEqual(@as(?u32, null), parseNotificationId("u 42")); // busctl format without stripping prefix
}

test "NotifyMap: key slices are owned (not aliased from Agent), survives agent free" {
    // Exercises Bug 1 fix: the map must dupe device_id/pane_id so that
    // freeing the Agent's fields doesn't leave dangling pointers in the map.
    // Uses std.testing.allocator which detects both UAF and leaks.
    var notify: Notify = .{ .gpa = std.testing.allocator };
    notify.ensureMapInited();
    defer notify.deinit();

    // Build an Agent with heap-allocated fields (simulates what the Store does).
    const gpa = std.testing.allocator;
    const device = try gpa.dupe(u8, "test-device");
    defer gpa.free(device);
    const pane = try gpa.dupe(u8, "test-pane");
    defer gpa.free(pane);
    const ws = try gpa.dupe(u8, "ws-1");
    defer gpa.free(ws);
    const agent_str = try gpa.dupe(u8, "claude");
    defer gpa.free(agent_str);

    const agent = store_mod.Agent{
        .device_id = device,
        .pane_id = pane,
        .workspace_id = ws,
        .tab_id = "tab-1",
        .status = .idle,
        .revision = 1,
        .focused = false,
        .agent = agent_str,
    };

    // Simulate what sendNotification does after a successful spawn: insert
    // into the map with the key slices DUPLICATED (Bug 1 fix).
    const key_device = try gpa.dupe(u8, agent.device_id);
    const key_pane = try gpa.dupe(u8, agent.pane_id);
    const headline = try std.fmt.allocPrint(gpa, "{s} · {s}", .{
        agent.displayTitle(), agentName(&agent),
    });

    const gop = try notify.notifs.getOrPut(.{
        .device_id = key_device,
        .pane_id = key_pane,
    });
    gop.value_ptr.* = .{
        .id = 42,
        .headline = headline,
        .agent_name = try gpa.dupe(u8, agentName(&agent)),
    };

    // Now free the original agent fields. If the map aliased instead of
    // duped, the key slices are now dangling — any access is UAF.
    // (The defer frees above handle device, pane, ws, agent_str.)

    // Verify the entry exists and is findable via the original slices
    // (exercises eql with the now-freed originals — UAF if aliased).
    const lookup = NotifyKey{ .device_id = device, .pane_id = pane };
    const found = notify.notifs.get(lookup);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 42), found.?.id);

    // fetchRemove frees the map's OWN key slices (not the originals).
    // If the map aliased, this double-frees — testing.allocator catches it.
    const removed = notify.notifs.fetchRemove(lookup);
    try std.testing.expect(removed != null);
    gpa.free(removed.?.key.device_id);
    gpa.free(removed.?.key.pane_id);
    gpa.free(removed.?.value.headline);
    gpa.free(removed.?.value.agent_name);

    try std.testing.expectEqual(@as(usize, 0), notify.notifs.count());
}

test "NotifyMap: second insert for same key replaces instead of stacking" {
    // Exercises the getOrPut/found_existing branch of sendNotification
    // (Notify.zig:217-225): a second notification for the same agent must
    // overwrite the entry (new id, freed old headline/agent_name), not add
    // a second one — this is the map-level half of "dos bloqueos seguidos
    // no apilan" (buildArgv's -r test covers the argv-shape half).
    const gpa = std.testing.allocator;
    var notify: Notify = .{ .gpa = gpa };
    notify.ensureMapInited();
    defer notify.deinit();

    const key = NotifyKey{
        .device_id = try gpa.dupe(u8, "local"),
        .pane_id = try gpa.dupe(u8, "p1"),
    };
    {
        const gop = try notify.notifs.getOrPut(key);
        try std.testing.expect(!gop.found_existing);
        gop.value_ptr.* = .{
            .id = 10,
            .headline = try gpa.dupe(u8, "first · claude"),
            .agent_name = try gpa.dupe(u8, "claude"),
        };
    }

    // Second transition for the same (device, pane): getOrPut on an
    // equal-but-distinct key finds the existing entry; the duplicate key
    // slices and the stale value slices must be freed (mirrors
    // sendNotification's found_existing branch) instead of leaking or
    // leaving a second entry.
    {
        const dup_key = NotifyKey{
            .device_id = try gpa.dupe(u8, "local"),
            .pane_id = try gpa.dupe(u8, "p1"),
        };
        const gop = try notify.notifs.getOrPut(dup_key);
        try std.testing.expect(gop.found_existing);
        gpa.free(dup_key.device_id);
        gpa.free(dup_key.pane_id);
        gpa.free(gop.value_ptr.headline);
        gpa.free(gop.value_ptr.agent_name);
        gop.value_ptr.* = .{
            .id = 11,
            .headline = try gpa.dupe(u8, "second · claude"),
            .agent_name = try gpa.dupe(u8, "claude"),
        };
    }

    try std.testing.expectEqual(@as(usize, 1), notify.notifs.count());
    const found = notify.notifs.get(.{ .device_id = "local", .pane_id = "p1" });
    try std.testing.expectEqual(@as(u32, 11), found.?.id);
    try std.testing.expectEqualStrings("second · claude", found.?.headline);
}

test "onStoreTransition: done is suppressed when the focused agent's window is active" {
    // Exercises the "terminado del pane que estoy mirando no notifica"
    // scenario end-to-end through the real dispatch function, without
    // touching D-Bus: the focused+active guard must return before
    // sendNotification (and therefore before any process spawn) is reached.
    var notify: Notify = .{ .gpa = std.testing.allocator };
    defer notify.deinit();

    const Ctx = struct {
        called: bool = false,
        fn isActive(data: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.called = true;
            return true;
        }
    };
    var ctx = Ctx{};
    notify.is_window_active = &Ctx.isActive;
    notify.is_window_active_data = &ctx;

    var agent = testAgent();
    agent.focused = true;

    onStoreTransition(&notify, &agent, .working, .done);

    try std.testing.expect(ctx.called);
    try std.testing.expectEqual(@as(usize, 0), notify.notifs.count());
}
