//! TerminalView (#21): struct que posee un Terminal + RenderState bajo mutex.
//! No es aún una subclase GObject de gtk.GLArea — la conexión al widget real
//! se hace en el consumidor. Ver roadmap/designs/21-terminalview.md.
//!
//! En esta fase el renderer GL solo limpia el framebuffer con el color de fondo
//! de RenderState.colors; el atlas propio + shaders es un issue futuro (#26).
//! El valor está en: feed + mutex + beginUpdate/endUpdate por separado + clean()
//! + contador de filas subidas + resizeGrid → Terminal.resize.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Terminal = ghostty_vt.Terminal;
const RenderState = ghostty_vt.RenderState;

// Raw GL calls — no gobject binding, linked via build.zig `linkSystemLibrary("GL")`.
extern "c" fn glClearColor(r: f32, g: f32, b: f32, a: f32) void;
extern "c" fn glClear(mask: c_uint) void;
extern "c" fn glViewport(x: c_int, y: c_int, width: c_int, height: c_int) void;
const gl_color_buffer_bit: c_uint = 0x00004000;

pub const TerminalView = struct {
    terminal: Terminal,
    render_state: RenderState,
    mutex: std.Io.Mutex,
    io: std.Io,

    /// Contador de filas subidas en el frame más reciente (criterio 1).
    rows_uploaded_last_frame: usize = 0,

    /// Contador acumulado de frames renderizados.
    frame_count: u64 = 0,

    const Self = @This();

    pub fn init(io: std.Io, alloc: std.mem.Allocator, num_cols: u16, num_rows: u16) !Self {
        var terminal = try Terminal.init(io, alloc, .{ .cols = num_cols, .rows = num_rows });
        errdefer terminal.deinit(alloc);

        return Self{
            .terminal = terminal,
            .render_state = .empty,
            .mutex = .init,
            .io = io,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.render_state.deinit(alloc);
        self.terminal.deinit(alloc);
    }

    /// Cols actuales de la rejilla del terminal.
    pub fn cols(self: *const Self) u16 {
        return self.terminal.cols;
    }

    /// Rows actuales de la rejilla del terminal.
    pub fn rows(self: *const Self) u16 {
        return self.terminal.rows;
    }

    /// Alimenta bytes al terminal desde el hilo lector.
    ///
    /// Lock → vtStream → nextSlice → unlock. NO pinta — solo marca filas
    /// sucias en el terminal. El re-render se dispara aparte (queue_render
    /// del GLArea, gestionado por el consumidor).
    pub fn feed(self: *Self, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var stream = self.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice(bytes);
    }

    /// Callback de render para GLArea (hilo UI, contexto GL corriente).
    ///
    /// Lock → beginUpdate → unlock → subir filas sucias → endUpdate → clean().
    /// beginUpdate denormaliza estilos bajo el lock; endUpdate + clean() se
    /// ejecutan sin lock (solo escriben en memoria propia del RenderState).
    pub fn renderFrame(self: *Self, alloc: std.mem.Allocator, width: c_int, height: c_int) void {
        // 1. Lock → beginUpdate (denormaliza estilos bajo lock).
        self.mutex.lockUncancelable(self.io);
        self.render_state.beginUpdate(alloc, &self.terminal) catch |err| {
            self.mutex.unlock(self.io);
            std.log.warn("TerminalView: beginUpdate failed: {}", .{err});
            return;
        };
        self.mutex.unlock(self.io);

        // 2. Contar filas sucias (sin lock — solo lectura de row_data).
        const row_data = self.render_state.row_data.slice();
        const dirty_flags = row_data.items(.dirty);
        var dirty_count: usize = 0;
        for (dirty_flags) |d| {
            if (d) dirty_count += 1;
        }
        self.rows_uploaded_last_frame = dirty_count;

        // 3. endUpdate (denormaliza pending_styles, sin lock).
        self.render_state.endUpdate();

        // 4. GL: limpiar framebuffer con el color de fondo del terminal.
        if (width > 0 and height > 0) {
            glViewport(0, 0, width, height);
        }
        const bg = self.render_state.colors.background;
        glClearColor(
            @as(f32, @floatFromInt(bg.r)) / 255.0,
            @as(f32, @floatFromInt(bg.g)) / 255.0,
            @as(f32, @floatFromInt(bg.b)) / 255.0,
            1.0,
        );
        glClear(gl_color_buffer_bit);

        // 5. clean() — marca todo como consumido.
        self.render_state.clean();
        self.frame_count += 1;
    }

    /// Redimensiona la rejilla del terminal. El RenderState pasa a .full en
    /// el próximo beginUpdate (la propia Terminal.resize lo invalida).
    pub fn resizeGrid(self: *Self, alloc: std.mem.Allocator, new_cols: u16, new_rows: u16) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.terminal.resize(alloc, .{
            .cols = new_cols,
            .rows = new_rows,
        });
    }
};

test "feed SGR+texto, dirty antes y después de clean" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tv = try TerminalView.init(io, alloc, 80, 24);
    defer tv.deinit(alloc);

    // Primer beginUpdate tras init: .full por el resize inicial.
    try tv.render_state.beginUpdate(alloc, &tv.terminal);
    tv.render_state.endUpdate();
    try std.testing.expectEqual(.full, tv.render_state.dirty);
    tv.render_state.clean();
    try std.testing.expectEqual(.false, tv.render_state.dirty);

    // Alimenta SGR bold+rojo + texto (patrón vt_spike.zig:79-80).
    const stream_bytes =
        "Hello, Kelpie!\r\n" ++
        "\x1b[2;3H" ++
        "\x1b[1;31m" ++
        "X" ++
        "\x1b[0m" ++
        "\x1b[K";
    try tv.feed(stream_bytes);

    // beginUpdate: debe ver filas sucias (.partial).
    try tv.render_state.beginUpdate(alloc, &tv.terminal);
    try std.testing.expectEqual(.partial, tv.render_state.dirty);

    // Contar filas sucias antes de clean.
    {
        const row_data = tv.render_state.row_data.slice();
        const dirty_flags = row_data.items(.dirty);
        var dirty_count: usize = 0;
        for (dirty_flags) |d| {
            if (d) dirty_count += 1;
        }
        try std.testing.expect(dirty_count > 0);
    }

    tv.render_state.endUpdate();
    tv.render_state.clean();

    // Después de clean: 0 filas sucias, dirty = .false.
    {
        const row_data = tv.render_state.row_data.slice();
        const dirty_flags = row_data.items(.dirty);
        var dirty_count: usize = 0;
        for (dirty_flags) |d| {
            if (d) dirty_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), dirty_count);
    }
    try std.testing.expectEqual(.false, tv.render_state.dirty);

    // Verificar que la celda (fila 1, col 2) es bold + fg rojo de paleta.
    {
        const row_data = tv.render_state.row_data.slice();
        const cell = row_data.items(.cells)[1].get(2);
        try std.testing.expect(cell.raw.hasStyling());
        try std.testing.expect(cell.style.flags.bold);
        try std.testing.expectEqual(1, cell.style.fg_color.palette);
    }
}

test "clean() deja dirty .false hasta la siguiente escritura" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tv = try TerminalView.init(io, alloc, 40, 5);
    defer tv.deinit(alloc);

    // Primer update: .full.
    try tv.render_state.beginUpdate(alloc, &tv.terminal);
    tv.render_state.endUpdate();
    tv.render_state.clean();

    // Segundo update sin alimentar: .false, 0 filas.
    try tv.render_state.beginUpdate(alloc, &tv.terminal);
    try std.testing.expectEqual(.false, tv.render_state.dirty);
    {
        const row_data = tv.render_state.row_data.slice();
        const dirty_flags = row_data.items(.dirty);
        var dirty_count: usize = 0;
        for (dirty_flags) |d| {
            if (d) dirty_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), dirty_count);
    }
    tv.render_state.endUpdate();
}

test "resizeGrid cambia dimensiones" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tv = try TerminalView.init(io, alloc, 80, 24);
    defer tv.deinit(alloc);

    try tv.resizeGrid(alloc, 120, 40);
    try std.testing.expectEqual(@as(u16, 120), tv.cols());
    try std.testing.expectEqual(@as(u16, 40), tv.rows());
}
