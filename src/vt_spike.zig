const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Terminal = ghostty_vt.Terminal;
const RenderState = ghostty_vt.RenderState;

const cols: u16 = 40;
const rows: u16 = 5;

/// Stream fijo del diseño #4: texto plano, CUP, SGR bold+rojo, EL.
const stream_bytes =
    "Hello, Kelpie!\r\n" ++
    "\x1b[2;3H" ++
    "\x1b[1;31m" ++
    "X" ++
    "\x1b[0m" ++
    "\x1b[K";

/// Vuelca las filas marcadas sucias de `state` a `writer` con el formato
/// ROW/CELL del diseño. No reimplementa `ghostty-vt`: solo lee `row_data`
/// tal como lo hace el test oficial "dirty state" en render.zig.
fn dumpDirty(state: *RenderState, writer: *std.Io.Writer) !void {
    const row_data = state.row_data.slice();
    const dirty = row_data.items(.dirty);
    const cells = row_data.items(.cells);

    for (dirty, 0..) |is_dirty, y| {
        if (!is_dirty) continue;

        try writer.print("ROW {d}: \"", .{y});
        var x: usize = 0;
        while (x < cells[y].len) : (x += 1) {
            const cp = cells[y].get(x).raw.codepoint();
            const ch: u8 = if (cp == 0) ' ' else @intCast(cp);
            try writer.writeByte(ch);
        }
        try writer.print("\"\n", .{});

        x = 0;
        while (x < cells[y].len) : (x += 1) {
            const cell = cells[y].get(x);
            if (!cell.raw.hasStyling()) continue;
            try writer.print("  CELL col={d} bold={} fg=", .{ x, cell.style.flags.bold });
            switch (cell.style.fg_color) {
                .palette => |idx| try writer.print("palette:{d}\n", .{idx}),
                .none => try writer.print("none\n", .{}),
                .rgb => try writer.print("rgb\n", .{}),
            }
        }
    }
}

/// Cuenta cuántas filas de `state.row_data` están marcadas sucias.
fn countDirtyRows(state: *RenderState) usize {
    const dirty = state.row_data.slice().items(.dirty);
    var n: usize = 0;
    for (dirty) |d| {
        if (d) n += 1;
    }
    return n;
}

test "spike C: bytes con SGR/CSI a Terminal, volcado de filas sucias vía RenderState" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var t: Terminal = try .init(io, alloc, .{ .cols = cols, .rows = rows });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();

    var state: RenderState = .empty;
    defer state.deinit(alloc);

    // Primer update() tras init: siempre .full por el resize inicial.
    try state.update(alloc, &t);
    try std.testing.expectEqual(.full, state.dirty);
    state.clean();

    // Alimenta el stream fijo del diseño.
    stream.nextSlice(stream_bytes);

    // Segundo update(): ya en modo .partial, solo filas 0 y 1 sucias.
    try state.update(alloc, &t);
    try std.testing.expectEqual(.partial, state.dirty);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try dumpDirty(&state, &out.writer);

    const expected = @embedFile("testdata/expected.txt");
    try std.testing.expectEqualStrings(expected, out.writer.buffered());

    // Escenario: la celda (fila 2, col 3) es bold + fg rojo de paleta.
    {
        const row_data = state.row_data.slice();
        const cell = row_data.items(.cells)[1].get(2);
        try std.testing.expect(cell.raw.hasStyling());
        try std.testing.expect(cell.style.flags.bold);
        try std.testing.expectEqual(1, cell.style.fg_color.palette);
    }

    // Tercer update(): clean() deja 0 filas sucias hasta la siguiente escritura.
    state.clean();
    try state.update(alloc, &t);
    try std.testing.expectEqual(.false, state.dirty);
    try std.testing.expectEqual(0, countDirtyRows(&state));

    // Cuarto update(): escribir una letra deja exactamente una fila sucia.
    stream.nextSlice("Y");
    try state.update(alloc, &t);
    try std.testing.expectEqual(.partial, state.dirty);
    try std.testing.expectEqual(1, countDirtyRows(&state));
}
