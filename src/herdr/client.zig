const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const json = std.json;

/// Minimal NDJSON-RPC client over a Unix domain socket.
/// One request per connection (herdr closes after responding),
/// except for `events.subscribe` which keeps the stream open.
pub const Connection = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buf: [read_buf_size]u8 = undefined,
    write_buf: [write_buf_size]u8 = undefined,

    const read_buf_size = 64 * 1024;
    const write_buf_size = 64 * 1024;

    /// Open a connection to the herdr Unix socket.
    /// `socket_path` must be ≤ 108 bytes (UnixAddress.max_len).
    ///
    /// `self` is an out-parameter: the caller must have already placed it at
    /// its final memory address (e.g. a local `var`) before calling `open`,
    /// and must never move/copy it afterwards. `reader`/`writer` build a
    /// `net.Stream.Reader`/`Writer` whose `.interface.buffer` points at
    /// `self.read_buf`/`self.write_buf` — if `self` moves, those become
    /// dangling pointers.
    pub fn open(self: *Connection, io: Io, socket_path: []const u8) !void {
        const addr = try net.UnixAddress.init(socket_path);
        const stream = try addr.connect(io);
        errdefer stream.close(io);

        self.stream = stream;
        self.reader = stream.reader(io, &self.read_buf);
        self.writer = stream.writer(io, &self.write_buf);
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        self.stream.close(self.reader.io);
    }

    /// Send a JSON request and read one JSON response line.
    /// Returns the raw response line (caller owns nothing — buffer is internal).
    pub fn sendRequest(
        self: *Connection,
        request: anytype,
    ) ![]u8 {
        // Serialize request to the writer buffer, then flush.
        try json.Stringify.value(request, .{}, &self.writer.interface);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();

        // Read one NDJSON line from the server.
        return self.reader.interface.takeDelimiterExclusive('\n');
    }
};

/// Resolve the herdr socket path from environment or default.
/// Returns a slice into `buf` (caller provides storage).
pub fn resolveSocketPath(
    environ: std.process.Environ.Map,
    buf: *[std.fs.max_path_bytes]u8,
) ![]const u8 {
    if (environ.get("HERDR_SOCKET_PATH")) |p| return p;

    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const suffix = "/.config/herdr/herdr.sock";
    if (home.len + suffix.len > buf.len) return error.PathTooLong;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    return buf[0 .. home.len + suffix.len];
}
