# Auditoría adversaria — #21 TerminalView

**VEREDICTO: DENEGADO**

Rama `feature/21-terminalview`, artefacto congelado `403d377..14afbec` (3 commits, 6 archivos,
+1239 líneas). Auditor: Claude Opus 5, 2026-09-07.

La denegación es **mecánica y con arreglo verificable** — se lista abajo como arreglos, no es veto
sobre el enfoque. El diseño es correcto; lo que falla es que el widget real no ejecuta el contrato
que el diseño describe, y los tests que lo prueban no prueban ese widget.

---

## Resumen ejecutivo

El diff entrega **dos implementaciones paralelas** del mismo contrato:

| | `src/terminal/TerminalView.zig` | `src/terminal/TerminalWidget.zig` |
|---|---|---|
| Qué es | struct plano, no GObject | subclase real de `gtk.GLArea` |
| Lock | `std.Io.Mutex` (barrera real, verificada) | spinlock `cmpxchg` (barrera real) |
| Dibuja filas | **no** — solo `glClear` del fondo | sí (`drawDirtyRows` → `drawRowTexture`) |
| Consumidor de producción | **ninguno** | `--terminalview-harness` (`src/main.zig:70`) |
| Tests | 6 (todos los Gherkin headless) | **0** |

Los 6 escenarios Gherkin cubiertos se ejecutan sobre `TerminalView`, que **no sube ninguna fila a
ninguna textura** y no tiene `queue_render`. El widget que sí implementa el contrato del issue no
tiene un solo test, y sus dos eslabones críticos de la cadena de activación están muertos.

---

## (a) Tabla de citas — verificada línea por línea con `sed -n`

El builder no adjuntó tabla propia (cuerpo de `09ffce1` es prosa, sin tabla). Se verificó la tabla
del diseño `roadmap/designs/21-terminalview.md` §«Firmas de API», que es la que el código usa.

| Cita del diseño | `sed -n` ejecutado | Resultado |
|---|---|---|
| `Terminal.init(io_impl, alloc, opts)` @ `Terminal.zig:311` | `sed -n '308,316p'` | ✅ exacta |
| `Terminal.resize(self, alloc, opts: Resize) ResizeError!void` @ `:4025` | `sed -n '4023,4030p'` | ✅ exacta |
| `Resize{cols, rows, cell_size_px?=null}` @ `:3983-3991` | `sed -n '3983,3991p'` | ✅ exacta |
| `Terminal.vtStream(self) Stream` @ `:380` | `sed -n '374,392p'` | ✅ exacta (**y ver hallazgo A1**) |
| `RenderState.Dirty` = `.false/.partial/.full` @ `render.zig:281-292` | `sed -n '281,292p'` | ✅ exacta |
| `beginUpdate` @ `render.zig:373` | `sed -n '370,376p'` | ✅ exacta |
| `endUpdate` @ `render.zig:754` | `sed -n '750,758p'` | ✅ exacta (+ doc confirma «no terminal lock required») |
| `row_data: MultiArrayList(Row)` @ `render.zig:97` | `sed -n '92,100p'` | ✅ exacta |
| `clean()` limpia las dos capas @ `render.zig:818-820` | `sed -n '814,824p'` | ✅ exacta |
| `Cell.raw` / `Cell.style` indefinido sin styling @ `render.zig:264-277` | `sed -n '260,280p'` | ✅ exacta |
| `hasStyling()` @ `page.zig:2291-2293` | `sed -n '2289,2295p'` | ✅ exacta |
| callbacks `gl_render`/`gl_resize` @ `surface.zig:3893-3898` | `sed -n '3890,3900p'` | ✅ exacta |
| `glareaRender(...) callconv(.c) c_int` @ `surface.zig:3408-3424` | `sed -n '3406,3426p'` | ✅ exacta |
| `queueRender` @ `surface.zig:827` | `sed -n '820,832p'` | ✅ exacta (`redraw()` → `gl_area.queueRender()`) |
| avance forzado a celda @ `grid_widget.zig:212-217` | `sed -n '210,219p'` | ✅ exacta |
| `linkSystemLibrary("GL")` @ `build.zig:53-57` | `sed -n '50,60p'` | ✅ exacta |
| patrón `theme_css_mod` @ `build.zig:85-91` | `sed -n '83,95p'` | ✅ exacta |
| bloque `test {}` @ `main.zig:109-117` | `sed -n '107,126p'` | ✅ exacta |
| patrón feed `vt_spike.zig:79-80` | `sed -n '74,84p'` | ✅ exacta |

**Cero citas falsas.** El diseño está limpio en este eje. `Screen.assertIntegrity` (que el commit de
QA invoca como sabotaje) existe en `Screen.zig:361` y está **activo**: `build/Config.zig:725-731`
pone `slow_runtime_safety = true` en `.Debug`, que es el modo de `zig build test`. La afirmación de
sabotaje de `14afbec` es correcta.

### A1 — La cita `vtStream` es exacta y el código la contradice (BLOQUEANTE)

`~/.cache/ghostty-build/src/ghostty/src/terminal/Terminal.zig:374-379`, verbatim:

> `Important: this creates a new stream each time with fresh parser state. If you need to persist`
> `parser state across multiple writes (e.g. for handling escape sequences split across write`
> `boundaries), you must store and reuse the returned stream.`

Ambos `feed` crean y destruyen un `Stream` por llamada:

- `TerminalView.zig:71-73` — `var stream = self.terminal.vtStream(); defer stream.deinit();`
- `TerminalWidget.zig:152-154` — idéntico.

La §Cadena de activación del diseño dice literalmente `feed(bytes) ← hilo lector (#23)`. Un lector
de PTY entrega trozos arbitrarios: **toda secuencia de escape partida en la frontera de un trozo se
pierde o se malinterpreta**. El harness no lo ve porque alimenta 64 KiB de ASCII imprimible sin
escapes (`TerminalWidget.zig:672-675`), y los tests alimentan siempre un `feed` completo. Es el caso
peligroso exacto que la regla de verificación del repo persigue: **una cita verdadera usada al
revés**.

*Arreglo:* guardar el `Stream` en el struct/widget, inicializarlo en `init`/`setup`, `deinit`-arlo en
`deinit`, y que `feed` solo llame `nextSlice`.

---

## (b) Cadena de activación f108: feed → idle → queue_render

Se evaluó eslabón a eslabón sobre el **único camino real** (`--terminalview-harness`), porque
`TerminalView` no tiene consumidor de producción alguno (`grep` sobre `src/`: única referencia es
`src/main.zig:124`, dentro del bloque `test {}`).

| Eslabón | Sitio | ¿Se ejecuta? |
|---|---|---|
| hilo lector → `feed` | `harnessFeedThread:679` | ⚠️ sí, pero tras B1 |
| `feed` → `queueRenderFromAnyThread` | `TerminalWidget.zig:158` | ✅ |
| → `glib.idleAdd(onIdleQueueRender)` | `:163` | ✅ (`idleAdd` es thread-safe; `SOURCE_REMOVE` → 0, correcto) |
| idle → `GLArea.queueRender()` | `:168` | ✅ |
| vfunc `render` → `onRender` | `Class.init:521` | ✅ (`virtual_methods.render.implement`) |
| `onRender` → `beginUpdate` bajo lock | `:275-281` | ✅ |
| `onRender` → `drawDirtyRows` | `:302` | ✅ llamada… |
| `drawDirtyRows` → subir alguna fila | `:330` | ❌ **ROTO — ver B2** |
| `onRender` → `endUpdate` + `clean()` | `:305-306` | ✅ |

### B1 — El harness arranca con un `Allocator` por confusión de tipos (BLOQUEANTE)

`TerminalWidget.zig:642`:
```zig
_ = glib.idleAdd(onHarnessSetup, alloc.ptr);
```
`TerminalWidget.zig:650-651`:
```zig
const alloc_ptr: *std.mem.Allocator = @ptrCast(@alignCast(user_data));
const alloc = alloc_ptr.*;
```

`std.mem.Allocator.ptr` (`/usr/lib/zig/std/mem/Allocator.zig:19`) es *«The type erased pointer to the
allocator implementation»* — el estado del `DebugAllocator`, **no** un `*std.mem.Allocator`. Leer 16
bytes de ese estado como `{ptr, vtable}` produce un allocator basura, que acto seguido se pasa a
`tv.setup(harness_io, alloc, 200, 60)` → `Terminal.init` → primera asignación por un `vtable`
inventado. La doc del propio campo advierte que hasta *comparar* ese puntero es comportamiento
ilegal.

Es el único camino de arranque del harness, y el harness es el instrumento del criterio 2. Compila y
pasa CI porque nadie lo ejecuta en tests. **No lo lancé** (prohibido abrir ventanas Wayland), pero el
defecto es de tipos, no de entorno.

*Arreglo:* `harness_alloc` ya es global de módulo (`:604`) y `onHarnessSetup` ya lee `harness_io` de
la misma forma. Pasar `null` como `user_data` y usar `harness_alloc`. Una línea.

### B2 — Ninguna fila se sube nunca: los dos setters de `cell_w`/`cell_h` están muertos (BLOQUEANTE)

`drawDirtyRows:330` corta en seco si `cell_w <= 0`. `cell_w` solo se escribe en dos sitios:

- `onResize` (`:226-244`) — **cero conexiones**. `Class.init:522` lo dice: *«resize is a signal, not
  a virtual — connect in instance init»*, y `instanceInit`/`init` (`:174-190`) no conecta nada. Peor:
  el harness roba la señal con un handler vacío — `gtk.GLArea.signals.resize.connect(tv,
  &onHarnessResize)` (`:632`), y `onHarnessResize:667` tiene el cuerpo vacío.
- `updateCellMetrics` (`:258`) — llamada solo desde `onRealize` (`:223`), que tampoco se conecta
  nunca; el harness conecta `onHarnessRealize` (`:645`), cuerpo vacío.

`grep -rn 'onRealize\|onResize' src/` confirma cero sitios de conexión para ambos.

Consecuencia: `cell_w` vale 0 durante toda la vida del proceso → `drawDirtyRows` retorna en la
primera línea en **todos** los frames → el widget nunca dibuja una celda. El bucle de fps de
`onRender:308-324` mediría un `glClear` vacío, no el renderer. **Un gate de criterio 2 corrido hoy
mediría ruido y saldría verde por la razón equivocada.**

Esto es exactamente lo que la §Cadena de activación del diseño encargó verificar con sabotaje
(*«quitar el `queue_render`: el frame no llega»*). Ese sabotaje no se escribió: los tests de QA no
tocan `TerminalWidget`.

### B3 — Efecto secundario de B2: `ensureReady` tampoco corre

Como `onRealize` está muerto, `normal_desc`/`bold_desc`/`italic_desc`/`bold_italic_desc` y
`pango_ctx` quedan en `null` (`init:175-179`). Si se arregla B2 sin arreglar B3, la primera fila
sucia hace `self.normal_desc.?` (`:383-389`) sobre `null` → **panic en el camino de render**, que
CLAUDE.md prohíbe explícitamente («un panic mata la sesión»). Arreglar los dos juntos.

Además `onRealize:217-220` crea un **contexto GL nuevo** (`surface.createGlContext()`) en vez de usar
el del `GLArea`, y no lo libera nunca. El `GLArea` ya entrega el suyo por parámetro en `onRender`.

---

## (c) Marshal hilo-lector→UI y mutex: ¿barrera real o cosmética?

**Ambas barreras son reales, no cosméticas.** Verificado:

- `std.Io.Mutex` (`/usr/lib/zig/std/Io.zig:1587-1650`) es un futex real:
  `cmpxchgStrong(.unlocked,.locked_once,.acquire,.monotonic)` + `futexWait` + `swap(.unlocked,
  .release)`. `std.testing.io` es un `Io.Threaded` (`std/testing.zig:34-35`), así que el test de 4
  hilos de `TerminalView.zig:307` ejerce contención de verdad.
- El spinlock de `TerminalWidget` (`:99-107`) usa el mismo par `acquire`/`release`. Correcto como
  barrera de memoria.

Y el marshal está bien planteado: `feed` suelta el lock *antes* de `queueRenderFromAnyThread`
(`:156-158`), y el `queueRender` viaja por `g_idle_add` al hilo de UI. Ningún trazo de pintura ocurre
en el hilo alimentador. **Este eje del diseño se cumple.**

Tres reservas, ninguna bloqueante por sí sola:

### C1 — El spinlock gira sin cota ni cesión, y ahora el hold es largo
`spinLock:100-102` gira con `spinLoopHint()` sin techo ni `yield`. `CONCERNS.md:559-564` ya registra
este patrón exacto (`lockMap` de Notify) con la advertencia *«los holds son diminutos»*. Aquí no lo
son: el lock se sostiene durante `stream.nextSlice` de un trozo de **64 KiB** (`:150-156`), mientras
el hilo de UI puede estar girando al 100 % dentro de `onRender:275`. Es reincidencia sobre deuda ya
declarada, con la circunstancia atenuante invertida. `TerminalView` usa `std.Io.Mutex` y no tiene el
problema — la asimetría entre los dos archivos no está justificada en ningún sitio.

### C2 — `widget_io` es una variable muerta
`TerminalWidget.zig:609` se declara, `:128` se escribe, y `grep` no encuentra ninguna lectura. Ruido
que sugiere una barrera de `Io` que no existe.

### C3 — Fuga de instancia
`deinitResources` (`:133`) tiene **cero call sites** (`grep -rn 'deinitResources' src/`). `Class.init`
solo implementa `render`; no hay `dispose`/`unrealize`. El `Terminal` y el `RenderState` del widget
nunca se liberan. Vida-de-proceso hoy, fuga real cuando #22–#27 creen y destruyan widgets.
Menor: `setup:117-131` — si `alloc.create(RenderState)` falla, el `errdefer` destruye el puntero del
`Terminal` pero nunca llama a `Terminal.deinit`; fuga interna en OOM.

---

## (d) Fórmula NDC por fila en `drawRowTexture` (`:552-557`)

```zig
const pix_to_ndc = 2.0 / @as(f32, @floatFromInt(vp_height));
const y0: f32 = 1.0 - @as(f32, @floatFromInt(row)) * @as(f32, @floatFromInt(surf_h)) * pix_to_ndc;
const y1_ndc = y0 - @as(f32, @floatFromInt(surf_h)) * pix_to_ndc;
```

La orientación es **correcta**: `t=0` mapea al vértice superior (`y0`), y la primera fila de datos de
una superficie cairo es la de arriba, así que la textura no sale invertida. `x0=-1..x1=1` es
consistente porque la superficie se crea con ancho `vp_width` completo (`:345`).

### D1 — Deriva acumulada por celda no entera
`surf_h = cell_h_i = @ceil(cell_h)` (`:331`), pero el origen de la fila `y` debería ser `y * cell_h`,
no `y * ceil(cell_h)`. Con 900 px / 60 filas → `cell_h = 15.0`, `ceil = 15`, coincide y el harness no
lo ve. Con cualquier rejilla de altura no entera (900/24 = 37.5 → 38) las filas se separan 0.5 px
extra cada una: **12 px de deriva al pie de una rejilla de 24**, y el alto del quad también usa el
`ceil`, así que las filas se solapan en la misma fracción. Muerde en cuanto #22 derive la rejilla de
métricas de fuente reales.
*Arreglo:* `y0 = 1.0 - row * cell_h * pix_to_ndc` (usar `cell_h`, `f64`, no el `surf_h` redondeado),
y el alto del quad igual.

### D2 — Canales R/B intercambiados y alfa doblemente premultiplicado
`glTexImage2D(..., gl_rgba, gl_unsigned_byte, data)` (`:540-550`) sobre datos de una superficie
`cairo` `.argb32`. `CAIRO_FORMAT_ARGB32` es **BGRA en orden de bytes nativo little-endian y con alfa
premultiplicado**. Subirla como `GL_RGBA` intercambia rojo y azul; combinarla con
`glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)` (`:560`) multiplica el alfa por segunda vez.
*Arreglo:* `GL_BGRA` como formato y `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`.

### D3 — `imageGetData()` sin `flush()` previo
`:528` lee el buffer crudo de la superficie inmediatamente después de dibujar con cairo, sin
`cairo_surface_flush()`. El contrato de cairo exige el flush antes de tocar los datos de una
superficie con operaciones pendientes.

### D4 — Modo inmediato sobre un contexto GTK4 (riesgo del gate, no confirmado)
`glBegin`/`glEnd`/`glTexCoord2f`/`glVertex2f`/`glEnable(GL_TEXTURE_2D)` (`:559-575`) son pipeline
fijo, eliminado del perfil *core*, que es lo que GDK pide por defecto para un `GtkGLArea`. Si el
contexto sale core, cada llamada da `GL_INVALID_OPERATION` y no se dibuja nada — el mismo síntoma
visible que B2, con causa distinta. **No lo verifiqué** (prohibido abrir ventanas Wayland). El
diseño §Riesgos ya avisó de que *«el renderer GL no tiene número propio todavía»*. Debe resolverse
antes del gate del criterio 2, o el gate no sabrá qué está midiendo.
Menor: `glPixelStorei(UNPACK_ROW_LENGTH/ALIGNMENT)` (`:538-539`) nunca se restaura.

---

## (e) `onResize` deriva rejilla y redimensiona el `Terminal` bajo lock

La lógica escrita es **correcta**: `onResize:230-243` deriva `new_cols`/`new_rows` de
`width/cell_w`, con `@max(1, …)` que evita la rejilla de cero, y solo actúa si cambian; delega en
`resizeGridLocked:246-256`, que toma el spinlock con `defer spinUnlock` y llama
`t.resize(alloc, .{.cols, .rows})` con la firma verificada, con `catch |err| std.log.warn` en vez de
`unreachable`. Se ajusta al diseño.

**Pero no se ejecuta nunca** (B2): la señal `resize` del `GLArea` está conectada al handler vacío del
harness. `resizeGridLocked` tiene un único call site y es `onResize`, que tiene cero. La rama entera
es código muerto en el único binario que existe.

Nota menor: `:236-237` recalcula `cell_w = width / grid_cols` *después* de un resize exitoso, lo que
hace la métrica de celda un cociente de la rejilla en vez de una propiedad de la fuente. Se
autoestabiliza, pero es la inversión de lo que #22 va a necesitar; el diseño ya lo señala como
frontera con #22.

---

## (f) Cero `unreachable` en `src/terminal/`

✅ **CONFIRMADO.** `grep -rn 'unreachable' src/terminal/` → cero ocurrencias. Los tres fallos posibles
del camino de render (`beginUpdate` en `TerminalView.zig:84` y `TerminalWidget.zig:276`, `resize` en
`:250`) se registran con `std.log.warn` y retornan sin abortar. Escenario Gherkin 5 cumplido.

Salvedad, para que el criterio no se lea como más fuerte de lo que es: B3 introduce un `.?` sobre
`null` en el camino de render, que es un panic de la misma clase aunque no sea la palabra
`unreachable`. El escenario 5 busca el token, no la propiedad.

---

## (g) Superficie del diff

`git diff --stat 403d377..14afbec`: `CONCERNS.md`, `build.zig`, `roadmap/designs/21-terminalview.md`,
`src/main.zig`, `src/terminal/TerminalView.zig`, `src/terminal/TerminalWidget.zig`. Nada fuera de la
frontera declarada; `src/ui/app_shell.zig` y `src/omarchy/` intactos (lease del otro hijo respetado);
`build.zig.zon` intacto; cero dependencias nuevas (`GL` es `linkSystemLibrary`, patrón preexistente
en `build.zig:53-57`). ✅

### G1 — Un archivo fuera de la lista del diseño (f45/f54/f64)
La §«Archivos que se tocan» del diseño nombra **`src/terminal/TerminalView.zig` (nuevo)**, en
singular. El diff añade además `src/terminal/TerminalWidget.zig`, 686 líneas — el archivo que
concentra todo el riesgo (GL, GObject, spinlock, harness) y **todo el código sin test**. La
obligación del propio diseño era cruzar `--stat` contra su lista de archivos; el cruce falla.

No es un veto conceptual: el diseño decía «no es aún una subclase GObject… la conexión al widget real
se hace en el consumidor» y el builder decidió entregar el widget también. Es una decisión razonable
mal declarada. Pero deja dos verdades incompatibles en el árbol sobre quién es «el TerminalView», y
CLAUDE.md §ADR es claro sobre no reimplementar dos veces lo mismo.

### G2 — `zig build test` verde, con matiz
`zig build test` → **exit 0**. Suites: 6 → 7 (`grep -c addTest`), exactamente +1 como pide f107 y el
escenario 6. Los flakes de `herdr.LocalServer` (errno 111) aparecen en el log y están **fuera de
juicio** (#102, territorio ajeno), como se me instruyó.
Matiz: los 6 tests de `TerminalView.zig` corren **dos veces** — una por el módulo nuevo de
`build.zig:128-142` y otra por la referencia de `src/main.zig:124`. Inocuo, pero el diseño pedía una
de las dos vías, no las dos.

---

## (h) Cobertura Gherkin con sabotaje real

| Escenario | Estado | Nota |
|---|---|---|
| 1 — 1 fila sucia sube 1; `.full` sube 24 | ⚠️ parcial | `TerminalView.zig:244-282`. Test correcto y bien construido (el truco del doble `resizeGrid` para forzar `.full` es honesto y está comentado). Pero el observable aprobado era **«fila subida al atlas»** y lo que se mide es `countDirtyRows()` — filas *sucias*. `TerminalView` no sube nada a ninguna textura. En el widget que sí lo hace, el contador no existe y B2 lo dejaría en 0. |
| 2 — 1 MB @ 60 fps | ⏸️ fuera de juicio | Gate conjunto. Se advierte que el instrumento está roto: B1 + B2 + D4. |
| 3 — cada frame termina en `clean()`; frame sin cambios no sube nada | ✅ | `TerminalView.zig:205-230`. Verifica `.false` y 0 filas tras `clean()`. |
| 4-headless — resize pasa a `.full` | ⚠️ parcial | `TerminalView.zig:284-305`. Correcto sobre `TerminalView.resizeGrid`. El camino real (`onResize` → `resizeGridLocked`) no se toca y está muerto (E). Sub-caso `stty` PENDIENTE declarado, no simulado ✅. |
| 4-ventana | ⏸️ fuera de juicio | Gate conjunto. |
| 5 — cero `unreachable` | ✅ | Verificado independientemente (F). |
| 6 — `zig build test` con SGR + texto | ✅ | `TerminalView.zig:141-203`. Alimenta el patrón de `vt_spike.zig:79-80`, comprueba sucias > 0 antes y 0 + `.false` después, y además valida la guarda `cell.raw.hasStyling()` antes de `cell.style` — la trampa que el diseño marcó. Suites +1 ✅. |

**Sobre el sabotaje real.** El test de 4 hilos (`:307-371`) es el mejor del lote: marcas CSI
indivisibles por hilo, 50 repeticiones, y una aserción sobre el contenido final de cada fila que
falla si las secuencias se entrelazan — no depende de que salte `assertIntegrity`, aunque
`assertIntegrity` también está activo (verificado). Sabotaje legítimo del mutex de `TerminalView`.

Lo que **falta** es el sabotaje que el diseño encargó por nombre: *«quitar el `queue_render`: el
frame no llega»*. Ese eslabón vive solo en `TerminalWidget`, que tiene 0 tests. La obligación f108 del
diseño («toda feature colgada de callback/evento declara su cadena de activación») está declarada en
el documento y **no verificada en el código**: dos de sus eslabones resultaron muertos justamente
donde nadie miró.

---

## Cruce contra el digest «Reglas vigentes» de `lessons-learned.md`

| Regla | Veredicto |
|---|---|
| **Citas: toda llamada nueva del diff, no solo las del diseño** (f46/f48/f54) | ❌ El builder no entregó tabla; `09ffce1` es prosa. Las APIs GTK/GLib/cairo/Pango/GL nuevas (`virtual_methods.render.implement`, `glib.idleAdd`, `cairo.Surface.imageCreate`, `pangocairo.createLayout`, `gdk.GLContext.makeCurrent`, los 16 `extern "c" fn gl*`) no tienen cita de ninguna fuente. El §Huecos del diseño decía que el builder «las añade a su tabla de citas». No lo hizo. D2/D3 son consecuencia directa de ese hueco sin cerrar. |
| **Una cita prueba que EXISTE, no que se EJECUTE** (f108) | ❌ El corazón de la denegación: B2 y E. |
| **`createModule` + `addTest`; total de tests +1** (f107) | ✅ 6 → 7 suites. |
| **Cruzar `--stat` contra la lista de archivos del diseño** (f45/f54/f64) | ❌ G1. |
| **Invariantes de memoria a un test que falle en rojo** (f44/f51/f78) | ❌ Ningún test con allocator que falle. C3 (fuga) y `setup:117-131` (fuga en OOM) sin cobertura. |
| **Territorio disjunto; ledgers append-only** (f37/f61/f74/f81) | ✅ Solo `CONCERNS.md`, en append. `lessons-learned.md` no tocado. |
| **Huecos declarados verificados con `sed ±15`** (f65/f77) | ❌ Los dos huecos del diseño (marshal y `queue_render`) se cerraron en código sin cita ni verificación. |
| **YAGNI / recorte validado** (f83) | ⚠️ `TerminalView` es hoy un campo vivo que nadie actualiza: cero consumidores de producción, y el widget real no lo usa. La trampa que f83 describe. |
| **Deuda del producto a `CONCERNS.md`** | ✅ y honesta: las tres entradas `[2026-09-07] #21` son exactas y bien acotadas. Ver abajo. |

---

## Sobre las entradas `[2026-09-07] #21` de `CONCERNS.md`

Las tres son correctas y están bien redactadas — dicen qué se vio, por qué no se arregla ahora y qué
lo dispara. Ninguna se objeta. Dos matices:

1. **Instancia única (`widget_alloc`/`widget_io`).** La justificación es exacta: `Allocator` e `Io` no
   son tipos `extern` y no caben en el `extern struct`. Aceptada como deuda. Añádase que `widget_io`
   ni siquiera se lee (C2) y que la vía limpia estándar en zig-gobject es la estructura *private* del
   GObject, no un global de módulo — mencionarlo evita que #22 lo copie como patrón.
2. **Textura por fila y por frame.** Correcta y bien encuadrada («el criterio 2 es quien juzga, con el
   número medido, no con razonamiento»). Pero mientras B2 siga en pie el criterio 2 **no puede
   juzgar nada**: no se crea ni una textura. La entrada describe un coste que hoy no se paga porque
   el trabajo no ocurre.
3. **Flake de `LocalServer`.** Fuera de juicio, y la entrada dice lo correcto (re-run + enlace, no
   arreglo dentro de #21).

---

## Arreglos exigidos para APROBAR

Bloqueantes:

1. **B2** — conectar `onResize` y `onRealize` del widget (en `instanceInit` o vía
   `virtual_methods`/`signals`), y sacar los handlers vacíos del harness. Sin esto `cell_w` es 0 y
   no se dibuja ni una fila.
2. **B3** — garantizar `ensureReady()` antes del primer `drawDirtyRows`, o sustituir cada
   `self.*_desc.?` por un `orelse return` en el camino de render. Un `.?` sobre `null` es un panic
   en render.
3. **B1** — `onHarnessSetup` debe usar `harness_alloc`, no un `*std.mem.Allocator` fabricado desde
   `alloc.ptr`. Una línea.
4. **A1** — persistir el `Stream` en el struct y reutilizarlo entre `feed`s, en los dos archivos.
   El contrato de la fuente pinneada lo exige por escrito para un alimentador por trozos.
5. **Cobertura de `TerminalWidget`** — al menos el sabotaje que el diseño encargó: un test que
   demuestre que sin el `queue_render` el frame no llega, y uno que ejecute `onResize` → grid
   derivada → `Terminal.resize`. Hoy el archivo con todo el riesgo tiene cero tests.
6. **G1** — resolver la duplicidad: o `TerminalView` es el núcleo que `TerminalWidget` compone (y los
   tests entonces sí cubren el camino real), o desaparece. Dos verdades sobre el mismo contrato en
   el mismo directorio no pasan. Enmendar el diseño con la lista de archivos real.
7. **D4** — decidir y dejar escrito si el contexto del `GLArea` es core o compatibilidad. Si es core,
   el modo inmediato no dibuja y el criterio 2 mide un `glClear`. Debe cerrarse **antes** del gate.

No bloqueantes, exigibles antes del PR:

8. **D1** — usar `cell_h` (no `@ceil`) en el origen y el alto del quad.
9. **D2** — `GL_BGRA` + `glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`.
10. **D3** — `flush()` de la superficie cairo antes de `imageGetData()`.
11. **C1** — cota + `yield` en el spinlock, o unificar con `std.Io.Mutex` como en `TerminalView`.
12. **C3** — llamar a `deinitResources` desde `dispose`/`unrealize`; cerrar la fuga de OOM de `setup`.
13. **C2** — borrar `widget_io`.
14. **Tabla de citas** del builder para las APIs GTK/GLib/cairo/Pango/GL nuevas, con `sed -n` por
    línea, según el §Huecos del diseño (f46/f48/f54).

---

## Lo que está bien, y conviene no perder en la corrección

- Las 19 citas del diseño son exactas, sin una sola invención. Es el eje donde un builder externo
  suele romperse, y aquí no se rompió.
- `beginUpdate` bajo lock / `endUpdate` + `clean()` fuera, exactamente como manda `render.zig:750-758`.
- La guarda `cell.raw.hasStyling()` antes de `cell.style` está puesta en los dos archivos y además
  **probada** (`TerminalView.zig:199`). Era la trampa de memoria más fácil de pisar.
- Cero `unreachable`; todos los fallos por `std.log.warn`.
- El marshal `feed` → `g_idle_add` → `queueRender` suelta el lock antes de agendar: la separación de
  hilos del diseño está bien pensada.
- Cero hexadecimales de color en el código: todo sale de `rs.colors` / `palette_to_rgba`.
- El test de 4 hilos con marcas CSI es sabotaje de verdad.
- `CONCERNS.md` declara la deuda con honestidad, incluida la que juega en su contra.

---

**VEREDICTO: DENEGADO** — 7 arreglos bloqueantes, todos mecánicos y verificables. La spec es buena;
el widget no la ejecuta y los tests no miran al widget.
