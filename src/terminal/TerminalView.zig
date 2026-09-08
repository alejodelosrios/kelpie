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
const Stream = ghostty_vt.TerminalStream;

pub const TerminalView = struct {
    terminal: Terminal,
    render_state: RenderState,
    stream: Stream,
    stream_ready: bool,
    mutex: std.Io.Mutex,
    io: std.Io,
    alloc: std.mem.Allocator,

    /// Contador de filas subidas en el frame más reciente (criterio 1).
    rows_uploaded_last_frame: usize = 0,

    const Self = @This();

    /// Crea un TerminalView completo: alloc + init + initStream atómico.
    /// Si initStream falla, libera todo sin tocar stream sin inicializar.
    pub fn create(alloc: std.mem.Allocator, io: std.Io, num_cols: u16, num_rows: u16) !*Self {
        const view_ptr = try alloc.create(Self);
        errdefer alloc.destroy(view_ptr);

        var terminal = try Terminal.init(io, alloc, .{ .cols = num_cols, .rows = num_rows });
        errdefer terminal.deinit(alloc);

        view_ptr.* = Self{
            .terminal = terminal,
            .render_state = .empty,
            .stream = undefined,
            .stream_ready = false,
            .mutex = .init,
            .io = io,
            .alloc = alloc,
        };

        // Stream persistente: vtStream captura puntero al terminal, el cual
        // debe estar en su dirección final (Terminal.zig:374-379).
        view_ptr.stream = view_ptr.terminal.vtStream();
        view_ptr.stream_ready = true;

        return view_ptr;
    }

    pub fn deinit(self: *Self) void {
        if (self.stream_ready) self.stream.deinit();
        self.render_state.deinit(self.alloc);
        self.terminal.deinit(self.alloc);
    }

    pub fn destroy(self: *Self) void {
        const alloc = self.alloc;
        self.deinit();
        alloc.destroy(self);
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
    /// Lock → nextSlice (stream persistente) → unlock. NO pinta — solo
    /// marca filas sucias en el terminal. El re-render se dispara aparte
    /// (queue_render del GLArea, gestionado por el consumidor).
    pub fn feed(self: *Self, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.stream.nextSlice(bytes);
    }

    /// Cuenta filas sucias en el RenderState (criterio 1: el contador que el
    /// frame reporta). Sin GL: solo lee row_data. Se extrae de renderFrame para
    /// que QA la pruebe headless sin contexto GL.
    pub fn countDirtyRows(self: *Self) usize {
        const row_data = self.render_state.row_data.slice();
        const dirty_flags = row_data.items(.dirty);
        var dirty_count: usize = 0;
        for (dirty_flags) |d| {
            if (d) dirty_count += 1;
        }
        return dirty_count;
    }

    /// Redimensiona la rejilla del terminal. El RenderState pasa a .full en
    /// el próximo beginUpdate (la propia Terminal.resize lo invalida).
    pub fn resizeGrid(self: *Self, new_cols: u16, new_rows: u16) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.terminal.resize(self.alloc, .{
            .cols = new_cols,
            .rows = new_rows,
        });
    }

    /// beginUpdate wrapper: lock → denormalize → unlock.
    pub fn beginUpdate(self: *Self) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.render_state.beginUpdate(self.alloc, &self.terminal);
    }

    /// endUpdate wrapper: denormalize pending styles (no lock needed).
    pub fn endUpdate(self: *Self) void {
        self.render_state.endUpdate();
    }

    /// clean wrapper: mark all dirty as consumed.
    pub fn clean(self: *Self) void {
        self.render_state.clean();
    }
};

test "feed SGR+texto, dirty antes y después de clean" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    // Primer beginUpdate tras init: .full por el resize inicial.
    try tv.beginUpdate();
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
    try tv.beginUpdate();
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

    const tv = try TerminalView.create(alloc, io, 40, 5);
    defer tv.destroy();

    // Primer update: .full.
    try tv.beginUpdate();
    tv.render_state.endUpdate();
    tv.render_state.clean();

    // Segundo update sin alimentar: .false, 0 filas.
    try tv.beginUpdate();
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

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    try tv.resizeGrid(120, 40);
    try std.testing.expectEqual(@as(u16, 120), tv.cols());
    try std.testing.expectEqual(@as(u16, 40), tv.rows());
}

test "escenario 1: contador sube 1 fila tras feed de una linea; 24 tras full" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    // Primer beginUpdate: .full por el resize inicial → 24 filas sucias.
    try tv.beginUpdate();
    tv.render_state.endUpdate();
    try std.testing.expectEqual(.full, tv.render_state.dirty);
    try std.testing.expectEqual(@as(usize, 24), tv.countDirtyRows());
    tv.render_state.clean();
    try std.testing.expectEqual(@as(usize, 0), tv.countDirtyRows());

    // Alimentar texto que ensucia exactamente 1 fila (una sola linea, sin wrap).
    try tv.feed("Hello, Kelpie!");
    try tv.beginUpdate();
    try std.testing.expectEqual(.partial, tv.render_state.dirty);
    try std.testing.expectEqual(@as(usize, 1), tv.countDirtyRows());
    tv.render_state.endUpdate();
    tv.render_state.clean();

    // Forzar estado .full redimensionando (Terminal.resize invalida el
    // RenderState; setear dirty=.full a mano no marca las filas). Primero
    // salimos de la rejilla 80x24 y luego volvemos: el segundo resize
    // invalida de nuevo y el siguiente frame sube las 24.
    try tv.resizeGrid(80, 30);
    try tv.beginUpdate();
    try std.testing.expectEqual(.full, tv.render_state.dirty);
    tv.render_state.endUpdate();
    tv.render_state.clean();

    try tv.resizeGrid(80, 24);
    try tv.beginUpdate();
    try std.testing.expectEqual(.full, tv.render_state.dirty);
    try std.testing.expectEqual(@as(usize, 24), tv.countDirtyRows());
    tv.render_state.endUpdate();
}

test "escenario 4 headless: resizeGrid pasa el RenderState a .full" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    // Consumir el .full inicial.
    try tv.beginUpdate();
    tv.render_state.endUpdate();
    tv.render_state.clean();
    try std.testing.expectEqual(@as(usize, 0), tv.countDirtyRows());

    // Redimensionar: el próximo beginUpdate debe ver .full (rejilla inválida).
    try tv.resizeGrid(120, 40);
    try std.testing.expectEqual(@as(u16, 120), tv.cols());
    try std.testing.expectEqual(@as(u16, 40), tv.rows());
    try tv.beginUpdate();
    try std.testing.expectEqual(.full, tv.render_state.dirty);
    try std.testing.expectEqual(@as(usize, 40), tv.countDirtyRows());
    tv.render_state.endUpdate();
}

test "feed concurrente desde N hilos: cada linea unica llega intacta a su fila" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tv = try TerminalView.create(alloc, io, 80, 24);
    defer tv.destroy();

    // Consumir el .full inicial: sin esto un feed roto (que no alimenta) no
    // se distinguiría de un terminal recién iniciado.
    try tv.beginUpdate();
    tv.render_state.endUpdate();
    tv.render_state.clean();
    try std.testing.expectEqual(@as(usize, 0), tv.countDirtyRows());

    const thread_count: usize = 4;
    var threads: [thread_count]std.Thread = undefined;

    // Cada hilo posiciona el cursor en su fila (CSI <fila>;1H) y escribe una
    // marca única e indivisible (sin \r\n). Sin el mutex, las secuencias CSI
    // de hilos distintos se entrelazan y las marcas acaban corruptas o en la
    // fila equivocada — el grid final lo delata.
    const Worker = struct {
        fn run(view: *TerminalView, row: usize) void {
            var buf: [64]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[{d};1HQA_MARK_{d}_END", .{ row + 1, row }) catch return;
            var attempt: usize = 0;
            while (attempt < 50) : (attempt += 1) {
                view.feed(seq) catch return;
            }
        }
    };

    for (&threads, 0..) |*th, i| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{ tv, i });
    }
    for (&threads) |*th| th.join();

    // La rejilla sigue válida y el RenderState puede denormalizarse sin pánico.
    try std.testing.expectEqual(@as(u16, 80), tv.cols());
    try std.testing.expectEqual(@as(u16, 24), tv.rows());
    try tv.beginUpdate();
    tv.render_state.endUpdate();

    // Cada fila i debe contener la marca completa del hilo i: leer las celdas
    // de la fila como cadena y buscar "QA_MARK_{i}_END".
    const row_data = tv.render_state.row_data.slice();
    const cells_all = row_data.items(.cells);
    for (0..thread_count) |i| {
        var line_buf: [160]u8 = undefined;
        var len: usize = 0;
        const row_cells = cells_all[i];
        var col: usize = 0;
        while (col < row_cells.len and len < line_buf.len) : (col += 1) {
            const cp = row_cells.get(col).raw.codepoint();
            if (cp == 0) continue;
            const n = std.unicode.utf8Encode(@intCast(cp), line_buf[len..]) catch break;
            len += n;
        }
        const line = line_buf[0..len];
        var needle_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "QA_MARK_{d}_END", .{i}) catch return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }
    tv.render_state.clean();
}
