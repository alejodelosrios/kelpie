# Diseño — #4 Spike C — alimentar bytes con SGR y CSI a `Terminal` y volcar filas vía RenderState

> Aprobado por: Manuel Alejandro Ramirez · 2026-08-27 · rama `chore/4-spike-c-nucleo-vt`

## Spec

Un test Zig (`std.testing`) que crea un `Terminal` 40×5, le alimenta un stream VT fijo (texto plano,
`ESC[2;3H` CUP, `ESC[1;31m` SGR bold+rojo, `ESC[K` EL), actualiza un `RenderState` dos veces
(inicial + tras el stream), vuelca a un buffer las filas marcadas sucias como texto plano más un
marcador de estilo por celda estilada, y compara ese volcado byte a byte contra
`src/testdata/expected.txt` con `std.testing.expectEqualStrings`. Un tercer y cuarto `update()`
prueban el contrato de `clean()`: 0 filas sucias sin escritura nueva, exactamente 1 tras escribir
una letra.

**Archivos que se tocan:**
- `src/vt_spike.zig` (nuevo) — la función que arma el `Terminal`, alimenta el stream, vuelca filas
  sucias a un `std.io.Writer` y expone el/los `test` blocks. Vive junto a `src/main.zig` (mismo
  hotspot, sin territorio propio — como #2).
- `src/testdata/expected.txt` (nuevo) — la salida esperada del primer volcado (texto fijo, generado
  y congelado en el Apply; no se inventa a mano línea por línea, se genera corriendo el propio test
  una vez con la salida capturada y se congela como fixture).
- `build.zig` — añade `src/vt_spike.zig` como módulo de test (`b.addTest` adicional, o import desde
  `src/main.zig` si el test vive en el mismo archivo — a decidir en Apply por lo que sea más simple;
  de cualquier forma no toca la lógica de `ghostty` ya cableada).

**No entra:** PTY, hilos, GTK — igual que el issue. Sin abstracción de "renderer" reusable: es un
volcado de texto de un solo uso para este spike.

## Formato del volcado (contrato exacto para QA)

Por cada fila sucia iterada (orden ascendente de `y`, saltando limpias si el estado global es
`.partial`, todas si es `.full`, ninguna si es `.false` — ver contrato citado abajo):

```
ROW <y>: "<texto plano de la fila, celdas vacías como espacio>"
```

Por cada celda de esa fila con `cell.raw.hasStyling()` verdadero, una línea adicional:

```
  CELL col=<x> bold=<bool> fg=palette:<idx>
```

(el spike solo usa color de paleta vía SGR 31, así que `fg` siempre es la variante `.palette`; si
apareciera `.rgb` o `.none` sería un bug del propio spike, no un caso a formatear).

## Stream VT fijo

```
"Hello, Kelpie!\r\n"     // texto plano en la fila 0
"\x1b[2;3H"              // CUP: fila 2, col 3 (1-indexed) => y=1, x=2 en RenderState
"\x1b[1;31m"             // SGR: bold + fg rojo (paleta índice 1)
"X"                       // celda estilada en (fila 2, col 3)
"\x1b[0m"                 // reset SGR
"\x1b[K"                 // EL modo 0: borra desde el cursor (col 4) hasta fin de fila 2
```

Esto deja sucias exactamente las filas 0 y 1 tras el segundo `update()` (la primera `update()`,
justo después de `Terminal.init`, siempre es `.full` por el resize inicial — ver test citado abajo
— así que el volcado byte-a-byte contra `expected.txt` se toma tras el **segundo** `update()`, ya
en modo `.partial`).

## Firmas de API que se van a usar

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `pub const RenderState = terminal.RenderState;` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/lib_vt.zig:84` | ✅ |
| `pub const Terminal = terminal.Terminal;` / `TerminalStream` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/lib_vt.zig:93-94` | ✅ |
| `Terminal.init(io_impl: std.Io, alloc: Allocator, opts: Options) !Terminal` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:311-314` | ✅ (ya usado en #2) |
| `Terminal.deinit(self: *Terminal, alloc: Allocator) void` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:356` | ✅ |
| `Terminal.vtStream()` → `TerminalStream`, `.nextSlice(bytes)`, `.deinit()` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/example/zig-vt-stream/src/main.zig:1-30` y patrón idéntico en `src/terminal/render.zig` test `"dirty state"` (línea 1971-1972) | ✅ |
| `RenderState.empty` (valor inicial) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:128` | ✅ |
| `RenderState.update(self, alloc, t: *Terminal) Allocator.Error!void` (equivalente a `beginUpdate`+`endUpdate`) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:343-350` | ✅ |
| `RenderState.beginUpdate` / `RenderState.endUpdate` (fases, no usadas aquí — sin hilos en este spike, `update()` basta) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:373-378`, `:754` | ✅ |
| `RenderState.clean(self) void` — limpia `dirty` global y `row_data.items(.dirty)` en un solo paso | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:818-820` | ✅ |
| `RenderState.dirty: Dirty` (`.false` / `.partial` / `.full`) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:281-292` | ✅ |
| `RenderState.Row.dirty: bool` (por fila, dentro de `row_data: std.MultiArrayList(Row)`) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:204-231` | ✅ |
| `RenderState.Row.cells: std.MultiArrayList(Cell)`, `Cell{ raw: page.Cell, grapheme, style: Style }` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:264-280` | ✅ |
| Iteración manual de filas sucias (sin iterador con nombre en la fachada Zig — el iterador con nombre solo existe en el shim C, `src/terminal/c/render.zig:575-599`, no expuesto en `lib_vt.zig`): leer `state.dirty` y `state.row_data.slice().items(.dirty)` directamente, como hace el propio test oficial | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:1960-2003` (test `"dirty state"`) | ✅ |
| `page.Cell.hasStyling(self: Cell) bool` — `true` si `style_id != stylepkg.default_id`; guarda de lectura antes de tocar `cell.style` (comentario: "undefined unless the style_id is non-default") | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/page.zig:2291-2293` | ✅ |
| `cell.style.flags.bold: bool` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:1438` (uso en test), struct en `src/terminal/style.zig:21-42` | ✅ |
| `Style.fg_color: Color` — `union(Tag) { none, palette: u8, rgb: color.RGB }` | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/style.zig:22-56` | ✅ |
| `cells[y].get(x).raw.codepoint()` — acceso a texto plano por celda (`0` si la celda está vacía) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:1396-1400` | ✅ |
| Primer `update()` tras `init` siempre reporta `.full` (resize inicial); segundo `update()` sin cambios reporta `.false`; tras escribir, `.partial` con solo la fila tocada marcada | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:1960-2003` (test `"dirty state"`, patrón completo) | ✅ |
| `state.colors.palette: color.Palette` — para resolver `fg_color.palette` a RGB si hiciera falta imprimir el valor resuelto (el formato del volcado solo imprime el índice, no lo resuelve) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/terminal/render.zig:156-161` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: el volcado inicial coincide byte a byte con el fixture
  Dado un Terminal 40x5 recién creado
  Y un RenderState vacío tras un primer update() (dirty = .full, se ignora para el fixture)
  Cuando se alimenta el stream fijo (texto + CUP + SGR bold/rojo + EL) vía TerminalStream.nextSlice
  Y se llama update() por segunda vez (dirty pasa a .partial, filas 0 y 1 sucias)
  Y se vuelca cada fila sucia con el formato ROW/CELL definido en este diseño
  Entonces el volcado es igual, byte a byte, a src/testdata/expected.txt

Escenario: la celda (fila 2, col 3) reporta bold y fg rojo de paleta
  Dado el RenderState actualizado tras el stream fijo
  Cuando se lee la celda en y=1, x=2 (fila 2, col 3 en 1-indexed)
  Entonces cell.raw.hasStyling() es true
  Y cell.style.flags.bold es true
  Y cell.style.fg_color es la variante .palette con índice 1 (rojo SGR 31)

Escenario: clean() deja 0 filas sucias hasta la siguiente escritura
  Dado el RenderState ya volcado y clean() invocado
  Cuando se llama update() sin haber escrito nada nuevo en el Terminal
  Entonces state.dirty es .false
  Y ninguna fila en row_data.items(.dirty) es true (0 filas por la iteración manual)

Escenario: escribir una letra deja exactamente una fila sucia
  Dado el RenderState limpio del escenario anterior
  Cuando se escribe una sola letra en el Terminal vía TerminalStream.nextSlice
  Y se llama update()
  Entonces state.dirty es .partial
  Y exactamente una fila en row_data.items(.dirty) es true
```

## Riesgos y preguntas abiertas

- `expected.txt` no se puede citar de una fuente estática: es un fixture que nace de correr el
  propio volcado una vez y congelar su salida — el Apply lo genera y lo commitea, no lo escribe a
  mano carácter por carácter. Riesgo de que un cambio futuro en la fachada de `ghostty-vt` (API
  inestable, ADR-0001) invalide el fixture; aceptable para un spike de gate M0.
- Si `build.zig` necesita un target de test adicional para `src/vt_spike.zig` (en vez de vivir dentro
  de `src/main.zig`), la forma exacta de registrarlo (`b.addTest` extra vs. import desde el módulo
  raíz) se decide en Apply por lo más simple que compile — no cambia ninguna firma de `ghostty-vt`
  ni el territorio del builder.
