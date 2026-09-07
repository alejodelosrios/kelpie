# Diseño — #21 TerminalView: widget GTK4 que dibuja solo filas sucias del RenderState con GtkGLArea + renderer GL propio

> Aprobado por: orquestador (wA:p1, fleet ola M2, gates=scope,diseño) · 2026-09-07
>
> Rama `feature/21-terminalview`. Risk:high; cuello de botella de M2 (#22–#27 dependen de este contrato).
>
> Nota de Apply (2026-09-07): verificado contra el ADR en la fuente por el orquestador, no solo
> en este reporte. Desvíos aceptados del cuerpo del issue: observable del criterio 1 pasa de
> "nodo GSK reconstruido" a "fila subida al atlas"; `Terminal.resize` lleva struct `Resize`;
> sub-caso `stty` del criterio 4 PENDIENTE hasta el PTY de #23.

## Spec

Subclase de `gtk.GLArea` que posee un `Terminal` + `RenderState` bajo un mutex; el hilo que alimenta
nunca pinta y el hilo de UI solo sube al atlas las filas sucias.

**Contradicción título/cuerpo (resuelta aquí, no en código).** El título del issue dice
`GtkGLArea + renderer GL propio`; el cuerpo describe `snapshot` + nodos GSK por fila. El gate de M0
(#7) adoptó el **plan B GL** (ADR-0001 §Decisión punto 4: el Spike B midió ~28 fps con nodos GSK,
umbral 60) y mandató comentarios en #21, #22 y #26. Este diseño sigue al título + ADR + skill
`zig-libghostty` y **sustituye** el cuerpo en: `snapshot` → callback `render` de `GLArea`; "nodo GSK
reconstruido" → "fila subida al atlas"; el resto del cuerpo (mutex, `feed`, `clean()`, estilos,
`resize`) sigue vigente.

**Archivos que se tocan** (territorio de un solo builder; lease de la ola):
- `src/terminal/TerminalView.zig` (nuevo) — el widget.
- `build.zig` — módulo propio + `addTest` (lease hotspot; patrón `theme_css_mod`).
- `src/main.zig` — referencia del módulo en el bloque `test {}` (lease hotspot; sin esto sus tests
  nunca corren: el runner solo descubre el root + referencias explícitas).
- `CONCERNS.md`, `lessons-learned.md` — append-only compartido con el otro hijo de la ola; rebase
  sobre `develop` antes del PR.

**No entra** (del issue + YAGNI):
- PTY (#23: `feed` se prueba con harness sin PTY; el lector real llama a `feed`), entrada (#24),
  selección (#25), estilos de cursor y paleta del tema (#26: se usa la paleta por defecto; el color
  llega del CSS por plantilla cuando #26 exista), imágenes, ligaduras fusionadas (forzar avance a
  celda lo impide por diseño; hecho aceptado en #7), `src/ui/app_shell.zig` ni `src/omarchy/`
  (lease del otro hijo: #21 expone el widget y `resize(cols,rows)`; incrustarlo en la ventana es
  consumidor posterior).

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Cada fila la verificó el PM con `sed -n`. `G` =
`~/.cache/ghostty-build/src/ghostty/src`.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `Terminal.init(io, alloc, .{.cols,.rows})` | `G/terminal/Terminal.zig:311` | ✅ |
| `Terminal.resize(self, alloc, opts: Resize)` con `Resize{cols, rows, cell_size_px? = null}` | `G/terminal/Terminal.zig:4025`, `:3983-3991` | ✅ (ojo: NO es `resize(cols,rows)`; el `Resize` struct lleva las dimensiones) |
| `Terminal.vtStream(self) Stream` + `stream.nextSlice(bytes)` (vía de alimentación; patrón Spike C) | `G/terminal/Terminal.zig:380`, `src/vt_spike.zig:79-80` | ✅ |
| `RenderState.Dirty` = `.false` / `.partial` / `.full` | `G/terminal/render.zig:281-292` | ✅ |
| `beginUpdate` / `endUpdate` por separado (**nunca `update()`**: sostendría el lock durante la denormalización) | `G/terminal/render.zig:373`, `:754` | ✅ |
| Patrón Zig sin iterador: `row_data.items(.dirty)` (`row_iterator_next_dirty` solo existe en el shim C) | `G/terminal/render.zig:97`, `G/terminal/c/render.zig:575` | ✅ |
| `clean()` limpia las dos capas a la vez | `G/terminal/render.zig:818-820` | ✅ |
| Guarda obligatoria: `cell.raw.hasStyling()` antes de `cell.style` (`style` indefinido si `style_id` es default; `Cell` envuelve la cruda en `raw`) | `G/terminal/render.zig:264-269`, `:275-277`, `G/terminal/page.zig:2291-2293` | ✅ |
| `gtk.GLArea` con callbacks `gl_realize/unrealize/map/unmap/render/resize`; `glareaRender` dibuja y devuelve `c_int` | `G/apprt/gtk/class/surface.zig:3893-3898`, `:3408-3424` | ✅ |
| Avance forzado a celda tras `pango.shape` (`f_`-prefijos de zig-gobject; ligaduras no fusionan) | `src/ui/grid_widget.zig:212-217` | ✅ |
| `exe_mod.linkSystemLibrary("GL", .{})` sobre el módulo (GL crudo sin binding; no es dependencia zig-pkg nueva) | `build.zig:53-57` | ✅ |
| Módulo propio + `addTest` para que `zig build test` corra tests de un archivo que nadie importa aún | `build.zig:85-91` (patrón `theme_css_mod`) | ✅ |
| Bloque `test {}` en `main.zig` que referencia módulos para que el runner los descubra | `src/main.zig:109-117` | ✅ |

**Huecos declarados (no supuestos):** la señal exacta para pedir un re-render (`queue_render` sobre
`GLArea`) y el marshal hilo-lector→UI (`g_main_context_invoke` / `g_idle_add`) se fijan en el Apply
contra `context7` (GTK4 `GtkGLArea`, `g_main_context_invoke`) y el patrón `surface.zig:827`
(`queueRender`) + `App.zig:23` (nunca dibujar desde otro hilo) citados en el issue; el builder las
añade a su tabla de citas. El atlas propio + shaders no tienen número en este repo (hipótesis
heredada de Ghostty, #7 riesgo registrado): el criterio 2 lo mide, no lo presupone.

## Cadena de activación (f108: una cita prueba que EXISTE, no que se EJECUTA)

- `feed(bytes)` ← hilo lector (#23; en #21, el harness del criterio 2) → lock → `nextSlice` →
  unlock → `g_idle_add`/`invoke` → UI: `gtk_gl_area_queue_render`.
- `render` de `GLArea` (hilo UI, con contexto GL corriente) → lock → `beginUpdate` → unlock →
  subir solo filas sucias al atlas → `endUpdate` → `clean()` → contador de filas subidas del frame.
- `resize` del widget → dimensiones de rejilla (matemática de celda: #22) →
  `Terminal.resize(alloc, .{.cols,.rows})` → `RenderState` pasa a `.full` en el próximo `beginUpdate`.
- QA verifica cada eslabón con sabotaje (quitar el `queue_render`: el frame no llega; pintar desde
  el feeder: el test de hilo falla).

## Escenarios (Gherkin)

```gherkin
Escenario: un frame con 1 fila cambiada sube exactamente 1 fila; full sube todas (criterio 1)
  Dado el widget con rejilla 80x24 y el contador de filas subidas a cero
  Cuando se alimenta texto que ensucia 1 fila y se ejecuta un frame
  Entonces el contador reporta exactamente 1 fila subida
  Y tras forzar estado .full el siguiente frame sube las 24

Escenario: 1 MB en trozos de 64 KiB a 60 Hz sobre 200x60 mantiene ≥ 60 fps sin pintar desde el feeder (criterio 2; GATE CONJUNTO con orquestador, ventana Wayland real, NO correr solo)
  Dado el widget visible de 200x60 alimentado por el harness sin PTY
  Cuando se inyecta 1 MB en trozos de 64 KiB a 60 Hz
  Entonces el fps medido es ≥ 60 durante la ráfaga
  Y ningún trazo de pintura ocurre en el hilo que alimenta

Escenario: cada frame termina con clean(); un frame sin cambios no sube nada (criterio 3)
  Dado un frame recién pintado
  Cuando se ejecuta otro frame sin alimentar bytes entre medias
  Entonces state.dirty es .false y el contador de filas subidas es 0

Escenario: redimensionar cambia cols/filas; stty coincide cuando hay PTY (criterio 4; GATE CONJUNTO, parte PTY diferida a #23)
  Dado el widget visible
  Cuando la ventana se redimensiona a una rejilla derivada de #22
  Entonces t.cols/t.rows coinciden con la rejilla visible
  Y (cuando exista el PTY de #23) `stty size` dentro coincide; sin PTY este sub-caso queda PENDIENTE declarado, no simulado

Escenario: cero unreachable en el camino de render; errores por std.log (criterio 5)
  Dado el diff del PR
  Cuando se busca `unreachable` en src/terminal/ y en el callback render
  Entonces hay cero ocurrencias y los fallos de frame se registran con std.log sin abortar

Escenario: zig build test alimenta SGR + texto y comprueba sucias antes/después de clean() (criterio 6)
  Dado `zig build test` en verde
  Cuando el test del módulo alimenta SGR + texto (patrón src/vt_spike.zig:79-80)
  Entonces observa filas sucias > 0 antes de clean() y 0 + dirty .false después
  Y el TOTAL de suites de `zig build test` sube exactamente en 1 (una por módulo nuevo)
```

## Obligaciones del ledger que este diseño contrae (toda fila vigente que toca el issue deja rastro; f88/f92)

- Higiene OpenCode (f115): builder lee `Terminal.zig`/`render.zig`/`surface.zig` **por rangos**
  (medir con `awk END+wc -c` si > ~800 líneas o ~60 KB); todo `zig build`/`test`/`diff` grande va a
  `.log` + `echo $?`, **nunca `cmd | tail`**; rastro: comandos del reporte del builder.
- Citas (f46/f48/f54): la tabla del builder cubre TODA llamada nueva del diff (incluidas GTK/context7
  fijadas en el Apply), no solo las de este diseño; rastro: su tabla verificada por el PM con `sed`.
- Citas tras editar (f73/f100), `git diff HEAD -- f` (f90), `diff --stat` vs lista de archivos (f45/f54/f64):
  rastro: gates mecánicos del PM.
- Memoria (f44/f51/f78): invariantes con allocator que falle van a test en rojo primero; rastro: test.
- `createModule` + `addTest` y total de tests +1 (f107); rastro: `zig build test` verde + conteo.
- Huecos con `sed ±15` igual que citas (f65/f77); rastro: este §Huecos + tabla del builder.
- Territorio disjunto + ledgers append-only con rebase avisado (f37/f61/f74/f81); rastro: `git status/diff`.

## Riesgos y preguntas abiertas

- **El renderer GL no tiene número propio todavía** (#7: solo se probó contexto + clear). Si el
  criterio 2 falla su umbral se invoca la escalera de aborto del spike, no se baja el umbral.
- **Matemática píxel→rejilla y métricas de celda son de #22** (depende de #21, así que #21 expone
  `resize(cols,rows)` y #22 lo llama; el harness usa dimensiones fijas). Si #22 necesita un hook
  distinto, se enmienda este diseño, no el código a escondidas.
- **Criterios 2 y 4 abren ventana Wayland: se ejecutan con el orquestador** (orden del fleet);
  el builder entrega el harness y el PM no declara esos gates en verde solo.
- ¿`g_main_context_invoke` o `g_idle_add` para el marshal lector→UI? Lo decide el Apply contra
  context7 + `surface.zig:827`; la respuesta se anota en la skill si es generalizable, no en el ledger.
