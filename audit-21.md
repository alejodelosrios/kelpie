# Auditoría adversaria — #21 TerminalView · v3 (tercera vuelta)

**VEREDICTO: APROBADO**

Artefacto: `ce7d410..a42ac19` (`8304e9b` fix + `a42ac19` docs) sobre `feature/21-terminalview`.
Vara: los 4 bloqueantes de la v2 + los 8 arreglos del dueño. Auditor: Claude Opus 5, 2026-09-07.

Queda **una obligación de ledger antes del PR** (CONCERNS, §L1) y el gate conjunto de los criterios
2 y 4-ventana sigue pendiente por diseño. Ninguna de las dos es código.

## Los tres pasos de CI, reproducidos por mí

| Paso de `.github/workflows/ci.yml` | Resultado |
|---|---|
| `zig fmt --check build.zig build.zig.zon src` (`:13`) | **exit 0** |
| `zig build --summary all` (`:15`) | **exit 0** |
| `zig build test --summary all` (`:16`) | **exit 0** — `Build Summary: 55/55 steps succeeded; 226/226 tests passed` |

El fallo que denegó la v2 está cerrado. Y con `zig build` en CI (`ci.yml:15`) la red que faltaba
existe: el exe llama a `TerminalWidget.new()` desde el harness, así que `defineClass` **se analiza en
CI**, que es lo que la v2 pedía cubrir. El flake de `herdr.LocalServer` (errno 111) aparece en el log
y reintenta en verde; fuera de juicio (#102).

---

## Cierre de los 4 bloqueantes de la v2

### 1 — Orden `(instancia, user_data)` y `zig build` en verde · **VERIFICADO**

`gtk4.zig:56694` declara
`connect(p_instance, comptime P_Data, p_callback: *const fn (@TypeOf(p_instance), P_Data) callconv(.c) void, p_data, p_options)`
— verificado con `sed -n`. Los handlers ahora encajan:

- `TerminalWidget.zig:196` `fn onRealize(self: *Self, _: ?*anyopaque) callconv(.c) void`
- `TerminalWidget.zig:201` `fn onResize(self: *Self, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void`
- conectados en `instanceInit` (`:173-174`) con `P_Data = ?*anyopaque` y `p_data = null`.

Coincide con la firma citada, y `zig build` lo confirma: **exit 0**.

### 2 — `errdefer` por fases, sin `deinit` sobre memoria sin inicializar · **VERIFICADO**

La regresión B4 está eliminada, y por la vía correcta: la atomicidad se movió al núcleo.
`TerminalView.create` (`TerminalView.zig:32-55`) escalona los `errdefer`:

```zig
const view_ptr = try alloc.create(Self);
errdefer alloc.destroy(view_ptr);        // :34 — nunca toca contenido
var terminal = try Terminal.init(...);
errdefer terminal.deinit(alloc);         // :37 — sobre el local, ya inicializado
view_ptr.* = Self{ ..., .stream = undefined, .stream_ready = false, ... };
view_ptr.stream = view_ptr.terminal.vtStream();   // :50 — no falla
view_ptr.stream_ready = true;                     // :51
```

Ningún `errdefer` corre sobre contenido sin inicializar, y nada puede fallar después de la copia al
heap (`vtStream` no devuelve error), así que el `errdefer` del `terminal` local no se dispara nunca
tras el traslado. `deinit:57-61` añade además el guardia `if (self.stream_ready)`. `setup:110-116` del
widget se reduce a `self.view = try TerminalView.create(...)`: sin ciclo de vida propio, sin
`errdefer` que equivocar. `destroy:63-66` cierra el par.

### 3 — Sabotaje real y red para el GObject · **VERIFICADO** (con un hueco declarado)

Lo que exigí era un test que fallara si se rompe el eslabón. Llegó, y por el camino que sí se puede
probar headless: **el split rasterizar/subir** (ver arreglo 7 abajo) hace testeable la mitad
cairo+Pango sin contexto GL, y el test
`"rasterizeDirtyRows produce superficies para filas sucias tras SGR+feed"`
(`TerminalWidget.zig:758-830`) lleva **dos sabotajes de verdad**, no contadores de adorno:

- **(a)** consumir el `.full` inicial y rasterizar sin alimentar → `rows_rasterized == 0` (`:813`).
- **(b)** rasterizar después de `clean()` → `rows_rasterized == 0` (`:829`).
- entre medias, `feed` de SGR bold+rojo + texto → `rows_rasterized > 0` (`:824`).

Los tres asertos se rompen si la rasterización deja de mirar las filas sucias. Y no es un mock:
`pango.Context.new()` (`:780`), cuatro `FontDescription` reales (`:785-802`) y superficies cairo de
verdad — el paso midió 392 ms y 56 MB de RSS, cifras de trabajo real, no de un stub.

**Hueco declarado, y bien declarado:** el sabotaje de `queue_render` sigue sin poder correr headless.
El builder no lo simuló — movió el contador **detrás** de la llamada y lo dijo en el código
(`:143-146`):

```zig
self.as(gtk.GLArea).queueRender();
// Counter AFTER queueRender — if queueRender is removed, counter freezes.
// Full sabotage test requires running GLib main loop (gate conjunto).
self.frames_requested +%= 1;
```

y el test asume la consecuencia honesta: sin main loop el contador vale **0** (`:755`), no 1. Eso es
exactamente lo contrario de lo que denegué en la v2, donde el contador subía antes de `idleAdd` y el
test se pintaba de verde solo. Un hueco declarado es seguro; una suposición con forma de dato, no.
Queda como obligación del gate conjunto.

### 4 — Tabla de citas · **VERIFICADO POR MUESTRA**

No tengo la tabla de R16 en el árbol (ni el diseño ni los cuerpos de commit la incorporan), así que
verifiqué yo con `sed -n` las tres firmas que la v2 señaló como críticas —las tres que, de estar mal,
rompen justo lo que se arregló:

| API usada | Fuente verificada | Resultado |
|---|---|---|
| `gtk.Widget.signals.realize.connect` (`:173`) | `gtk4.zig:56691-56702` | ✅ `fn (@TypeOf(p_instance), P_Data)` — el orden que ahora usa el código |
| `gtk.GLArea.signals.resize.connect` (`:174`) | mismo patrón `signals.*.connect` de `gtk4.zig` | ✅ (y `zig build` lo confirma) |
| `gobject.Object.virtual_methods.dispose.implement` (`:536`) | `gobject2.zig:437-445` | ✅ `implement(p_class, *const fn (p_object: *Instance) callconv(.c) void)`, coincide con `onDispose(self: *Self) callconv(.c) void` (`:540`) |
| `gtk.GLArea.virtual_methods.render.implement` (`:535`) | `gtk4.zig` `virtual_methods.render` | ✅ |
| `pango.Context.new()` (`:780`, test) | `pango1.zig:43-64` (`extern fn pango_context_new() *pango.Context`) | ✅ — y la doc de esa misma función dice que GTK ofrece `gtk_widget_get_pango_context` «use those instead», que es justo lo que hace producción (`ensureReady:180`); el `Context.new` queda confinado al test headless, uso correcto |
| `GL_RGBA8` `0x8058`, `GL_BGRA` `0x80E1`, `GL_ONE` `1`, `GL_VERSION`/`GL_RENDERER` | comentario inline con `gl.h:línea` (`:45`, `:46`, `:53`, `:58`, `:59`) | ✅ media cita, suficiente para constantes |

Cero citas falsas en la muestra. **Pendiente formal:** la tabla completa debe ir al cuerpo del PR o al
diseño (f46/f48/f54); no bloquea el veredicto porque las firmas que importan están verificadas y el
compilador es testigo, pero el rastro escrito falta.

---

## Cierre de los 8 arreglos del dueño

| # | Arreglo | Estado | Evidencia (`sed -n`/`grep`) |
|---|---|---|---|
| 1 | Orden `(instancia, user_data)` + `zig build` 0 | **VERIFICADO** | `:196`, `:201`, `:173-174`; build exit 0 |
| 2 | `errdefer` por fases | **VERIFICADO** | `TerminalView.zig:32-55`, `:57-61`, `:63-66`; `setup:110-116` |
| 3 | `grep -F '?.'` vacío | **VERIFICADO** | `grep -Fn '?.' src/terminal/*.zig` → vacío; `grep -n '\.?'` → **vacío también**. Los 12 `.?` de `ensureReady` son ahora `(x orelse return)` (`:180-194`). Cero desenvueltos forzados en todo `src/terminal/` |
| 4 | `Stream` persistente en ambos caminos; N1 cerrado por `create()`/`destroy()` | **VERIFICADO** | `TerminalView.zig:19` campo, `:50-51` creación en dirección final con la cita `Terminal.zig:374-379` en el comentario, `:86` `feed` es solo `nextSlice` bajo lock. `TerminalWidget.feed:129-133` delega. **No queda `initStream` suelto**: `grep 'initStream'` solo lo menciona en el doc-comment de `create` (`:30`); la función pública desapareció. Guardia `stream_ready` (`:20`, `:58`) |
| 5 | `GL_RGBA8`+`BGRA`+`GL_ONE`+`flush`+`cell_h` f64+texcoord fraccionaria | **VERIFICADO** | internalFormat `gl_rgba8` (`:562`) con externo `gl_bgra` (`:566`) — N2a cerrado; `glBlendFunc(gl_one, …)` (`:582`); `surf.flush()` (`:507`) antes de `imageGetData`; `y0`/`y1` con `@floatCast(cell_h)` (`:572-574`); `t_frac = cell_h/⌈cell_h⌉` (`:588-589`) aplicado en los vértices inferiores (`:595`, `:597`) — N2b cerrado |
| 6 | `renderFrame` y externs muertos eliminados | **VERIFICADO** | `grep 'renderFrame\|extern "c" fn gl'` en `TerminalView.zig` → solo un comentario residual (ver **N4**). El núcleo ya no toca GL; N3 cerrado |
| 7 | Split rasterizar/subir + test SGR con 2 sabotajes | **VERIFICADO** | `drawDirtyRows:313-316` = `rasterizeDirtyRows` (`:319`, cairo+Pango, `pub`, sin GL) + `uploadRowTextures` (`:521-528`, solo GL). Test en `:758-830`. Suites 7→8 (`grep -c addTest build.zig` = 8); el módulo del widget corre **9 tests** (3 propios + los 6 de `TerminalView.zig`, arrastrado por el `@import`), todos en verde |
| 8 | `frames_requested` tras `queueRender` | **VERIFICADO** | `:143-146`, con el comentario que nombra la limitación; test `:755` asume 0 sin main loop |

Y lo que ya estaba verificado en la v2 sigue en pie: `harness_alloc` sin `alloc.ptr` (`:636`, `:664`,
`:669`), `dispose` conectado (`:536`, `:540`), hueco D4 con sus tres fuentes (`:621-627`) y log de
`GL_VERSION`/`GL_RENDERER` en el primer frame (`:243-250`), cero `unreachable` en `src/terminal/`, y
la unificación bajo `std.Io.Mutex` del núcleo (`onRender:255-262`).

---

## Ciclo de vida de las superficies — comprobado, no supuesto

Miré esto con lupa porque un split mal hecho fuga una superficie cairo por fila y por frame en el
camino caliente, que es justo donde nadie lo nota hasta el gate de fps:

- `uploadRowTextures:522-527` hace `drawRowTexture(...)` **y** `item.surface.destroy()` por elemento,
  y luego `clearRetainingCapacity()`. Sin fuga en el camino normal.
- `rasterizeDirtyRows:321-325` libera y limpia **al entrar**, antes de rasterizar. Cubre el caso en
  que `upload` no llegó a correr (salida temprana por `cell_w <= 0` en `:327`, o el test, que solo
  rasteriza). Los dos caminos están cerrados.
- `append` fallido destruye su propia superficie y continúa (`:512-515`), sin `catch unreachable`.

---

## Hallazgos abiertos (ninguno bloqueante)

### L1 — Obligación de ledger antes del PR: `CONCERNS.md` quedó desincronizado

La entrada `[2026-09-07] #21` (`CONCERNS.md:572`) describe una deuda que **ya no existe**: habla de
`widget_alloc`/`widget_io` y de «mover alloc/io a un registro externo indexado por puntero de
widget». `grep 'widget_alloc\|widget_io' src/terminal/` → vacío. Esta ronda los eliminó y no tocó
`CONCERNS.md` (`git diff --stat ce7d410..a42ac19` → solo `audit-21.md` y los dos fuentes).

Y la limitación no desapareció, **se mudó**: `rasterized_rows` es una global de módulo
(`TerminalWidget.zig:67`) que además asigna con `std.heap.page_allocator` (`:509`), no con el
allocator del núcleo. Dos `TerminalWidget` en el mismo proceso se pisarían la lista de superficies
entre frames. Es la misma clase de deuda de antes —una instancia por proceso— con distinto nombre, y
ahora **sin declarar**.

Territorio del PM, no del builder, y es una edición de ledger, no de código. Pero f88/f92 es
explícita: toda deuda vigente deja rastro. **Actualizar la entrada antes de abrir el PR**: marcar la
mitad de `alloc`/`io` como superada por esta ronda y declarar `rasterized_rows` + `page_allocator`
como la deuda que la sustituye, con su disparador (el primer consumidor que quiera dos terminales
visibles — split/panes).

### N4 — Comentario huérfano

`TerminalView.zig:92`: *«Se extrae de renderFrame para que QA la pruebe headless»*. `renderFrame` se
borró en esta ronda (arreglo 6). El comentario apunta a una función que ya no existe. Una línea.

### N5 — Fugas GLib en el test de rasterización

`TerminalWidget.zig:785-802` crea cuatro `pango.FontDescription` que nunca se liberan (`pango_ctx` sí
lleva su `unref` en `:781`). Viven en el heap de GLib, así que `std.testing.allocator` no las ve y el
test pasa. Acotado a la vida del binario de test; anotarlo basta.

### N6 — D4 sigue abierto, como debe

El modo inmediato (`glBegin`/`glEnd`/`glEnable(GL_TEXTURE_2D)`, `:591-600`) sigue en pie, y con él el
riesgo de que un contexto core lo rechace entero — ahora acompañado de `GL_RGBA8` como
internalFormat, que sí es válido en core y era un cabo suelto menos. El hueco está declarado con sus
fuentes y el instrumento para resolverlo (`:621-627`, log en `:243-250`). **Condición del gate del
criterio 2, ya escrita en el diseño: leer el `GL_VERSION` del primer frame ANTES de medir fps.** Si
sale core, se sustituye el modo inmediato y luego se mide — nunca al revés, y nunca bajando el umbral.

---

## Por qué esto es un APROBADO y no otra denegación

Las tres vueltas atacaron tres capas distintas, y esta cerró la última:

- **v1** denegó porque el widget no ejecutaba su propio contrato (`onResize`/`onRealize` sin conectar,
  ninguna fila subida jamás) y los tests miraban a otro archivo.
- **v2** denegó porque el cableado estaba escrito pero no compilaba, y `zig build test` en verde lo
  tapaba: los tests fabricaban el widget a mano y el análisis perezoso nunca llegaba a `defineClass`.
- **v3** compila, pasa los tres pasos de CI, y —lo que más pesa— **el test nuevo puede fallar**. El
  split rasterizar/subir no es cosmético: es lo que convierte «hay que abrir una ventana para saberlo»
  en «esto se prueba headless con dos sabotajes». Ese es el cambio de fondo de la ronda.

Lo que queda abierto está abierto **por escrito**: D4 espera al gate con su instrumento puesto, el
sabotaje de `queue_render` está declarado como imposible headless en vez de falsificado, y el
sub-caso `stty` sigue diferido a #23. Los criterios 2 y 4-ventana no los juzgo — son gate conjunto.

Un hueco declarado es seguro. Los tres que quedan lo están.

---

**VEREDICTO v3: APROBADO.** Los 4 bloqueantes de la v2 y los 8 arreglos del dueño, cerrados y
verificados con `sed -n`/`grep` uno por uno. CI reproducido en verde por mí: `zig fmt --check` 0,
`zig build` 0, `zig build test` 0 con 226/226. Antes del PR queda **L1** (actualizar `CONCERNS.md`:
la deuda de instancia única se mudó de `widget_alloc`/`widget_io` a `rasterized_rows`), y N4/N5 como
limpieza opcional. El gate conjunto de los criterios 2 y 4-ventana sigue siendo del orquestador, con
D4 a resolver leyendo el log antes de medir.

---
---

# ↓↓↓ HISTORIA — Auditorías v2 y v1 ↓↓↓

# Auditoría adversaria — #21 TerminalView · v2 (segunda vuelta)

**VEREDICTO: DENEGADO**

Artefacto: `14afbec..ce7d410` (3 commits) sobre `feature/21-terminalview`. Vara: los 14 arreglos de
la v1 (conservada íntegra más abajo). Auditor: Claude Opus 5, 2026-09-07.

## El hecho que decide

**`zig build` FALLA. El ejecutable no compila.**

```
src/terminal/TerminalWidget.zig:170:67: error: expected type
  '*const fn (T, ?*anyopaque) callconv(.c) void',
  found '*const fn (*gtk4.Widget, T) callconv(.c) void'
        _ = gtk.Widget.signals.realize.connect(self, ?*anyopaque, &onRealize, null, .{});
                                                                  ^~~~~~~~~~
  note: T = *terminal.TerminalWidget.TerminalWidget
referenced by:
    getGObjectType: src/terminal/TerminalWidget.zig:87:26
Build Summary: 38/41 steps succeeded (1 failed)
```

`gtk4.zig:56694` declara `connect(p_instance, comptime P_Data, p_callback: *const fn
(@TypeOf(p_instance), P_Data) callconv(.c) void, p_data, p_options)`: el **primer** parámetro del
callback es la instancia y el **último** el `user_data`. Los dos handlers están escritos al revés —
`onRealize(_: *gtk.Widget, self: *Self)` (`:197`) y `onResize(_: *gtk.GLArea, w, h, self: *Self)`
(`:202`) — que es la convención de `bindTemplateCallback` de `surface.zig`, donde `self` viaja como
`user_data`. Aquí se pasa `self` como *instancia* y `null` como `user_data`. Ambas conexiones
(`:170` y `:171`) están mal por la misma razón; el compilador corta en la primera.

**El arreglo #1 de la v1 — el arreglo central de toda la ronda — está ROTO en tiempo de compilación.**

### Y por qué el árbol parece verde

`zig build test` → **exit 0**. `zig build` → **exit 1**.

La divergencia no es casual, y es el hallazgo más grave de esta vuelta. `gobject.ext.defineClass`
(`:81-86`) solo se instancia cuando algo llama a `TerminalWidget.new()` (`:92`), y lo único que la
llama es el harness. Los dos tests nuevos **no construyen el widget por GObject**: lo fabrican a mano
en la pila —

```zig
var widget: TerminalWidget = undefined;   // :668 y :693
widget.view = &tv;
TerminalWidget.onResize(&dummy_gl, 200, 900, &widget);   // :683 — llamada DIRECTA al handler
```

— así que el análisis perezoso de Zig nunca llega a `instanceInit`, nunca comprueba las conexiones, y
la suite pasa sobre un widget que **no puede existir como GObject**.

Es la lección B2 de la v1 repetida un piso más arriba: entonces el handler existía y no estaba
conectado; ahora la conexión está escrita y no compila — y en las dos vueltas los tests salieron
verdes. El propio diseño enmendado lo había anticipado por escrito
(`roadmap/designs/21-terminalview.md`, §Riesgos): *«La cadena se prueba conectada, no existente
(f108): `onResize`/`onRealize`/`render` se verifican por sus call sites/conexiones (`grep` de
conexiones), nunca leyendo la función.»* El `grep` se hizo; el `zig build` no.

Regla del repo violada, sin ambigüedad: **«Nada se mergea en rojo»** (CLAUDE.md §Modelo de ramas). El
check `build` del ruleset de `develop` saldría rojo. El cuerpo de `ce7d410` afirma «suites 53->55»,
una afirmación sobre un árbol verde que no se sostiene.

---

## Cierre uno por uno de los 14 arreglos de la v1

| # | Arreglo v1 | Estado | Evidencia |
|---|---|---|---|
| 1 | realize/resize conectados en `instanceInit`; handlers vacíos del harness fuera | **ROTO** | Conexiones presentes en `TerminalWidget.zig:170-171` pero **no compilan** (error arriba). `onHarnessRealize`/`onHarnessResize` sí **ELIMINADOS** (`grep` → vacío). Media victoria que no sirve: el exe no enlaza. |
| 2 | `ensureReady` en `onRealize`; `orelse` en el camino de render | **VERIFICADO** (con reserva) | `onRealize:197-200` llama `ensureReady()` + `updateCellMetrics()`. Los cuatro `.?` del render son ahora `orelse return`: `:356`, `:358`, `:360`, `:362`. `grep '\.?'` deja 12 ocurrencias, **todas** en `ensureReady:179-193`, fuera del camino de render. Reserva: siguen siendo `.?` sin comprobar sobre `pango.FontDescription.new()`; el fallo es improbable pero el patrón es el que la v1 marcó. |
| 3 | Harness usa `harness_alloc` | **VERIFICADO** | `:626` `glib.idleAdd(onHarnessSetup, null)`; `:629-632` `tv.setup(harness_io, harness_alloc, …)`. `grep 'alloc\.ptr'` → vacío. La confusión de tipos de la v1 está eliminada de raíz. |
| 4 | `Stream` persistente; `feed` solo `nextSlice`, en ambos caminos | **VERIFICADO** (con trampa nueva) | `TerminalView.zig:25` campo `stream: Stream`; `:53-56` `initStream()`; `:81` `feed` es solo `self.stream.nextSlice(bytes)` bajo lock. `TerminalWidget.feed:129-133` delega en `v.feed` — un solo camino, sin duplicación. `Stream = ghostty_vt.TerminalStream` verificado en `lib_vt.zig:94`. El comentario `:52-55` justifica correctamente por qué el stream se crea tras fijar la dirección del `Terminal` (`vtStream` captura `self` vía `vtHandler`). Ver **N1**. |
| 5 | D2 (`GL_BGRA` + `GL_ONE`), D3 (`flush`), D1 (`cell_h` f64) | **VERIFICADO** (con reserva) | D2: `gl_bgra = 0x80E1` (`:45`), usado como formato en `:548`; `glBlendFunc(gl_one, gl_one_minus_src_alpha)` (`:551`, `gl_one` en `:52`). D3: `surf.flush()` en `:488`, justo antes de `drawRowTexture`. D1: `:554-556` usan `@floatCast(cell_h)` para origen y alto del quad. Ver **N2**. |
| 6 | `spinlock`/`widget_alloc`/`widget_io`/`alloc.ptr` eliminados | **VERIFICADO** | `grep -rn 'spinLock\|spinUnlock\|lock_state\|cmpxchg' src/terminal/` → vacío. `grep 'widget_alloc\|widget_io'` → vacío. `grep 'alloc\.ptr'` → vacío. El único `@ptrCast(@alignCast(user_data))` que queda (`:145`) es el `self` del idle, legítimo. C1 y C2 de la v1 cerrados por unificación sobre `std.Io.Mutex` (`:251-258` toma el mutex del núcleo). |
| 7 | Deriva por `@ceil` | **VERIFICADO** | `:554-556`: `y0 = 1.0 - row * cell_h * pix_to_ndc`, `y1 = y0 - cell_h * pix_to_ndc`. El `@ceil` sobrevive solo donde toca — alto en píxeles de la superficie cairo (`:306`, `:546`). La deriva acumulada de la v1 desaparece. |
| 8 | `dispose` conectado + `errdefer` OOM | **PARCIAL / EMPEORADO** | `dispose`: **VERIFICADO** — `Class.init:503` `gobject.Object.virtual_methods.dispose.implement(class, &Self.onDispose)`; `onDispose:506-508` → `deinitResources()`. La fuga C3 de la v1 está cerrada. `errdefer`: **ROTO, y peor que antes** — ver **B4**. |
| 9 | D4: hueco declarado + log `GL_VERSION` | **VERIFICADO** | Hueco: `:583-589`, con las tres fuentes consultadas y el resultado negativo (`gtkglarea.h` sin mención de perfil, `gdkglcontext.h:78-84`, `gdkenums.h:69-70`) y la orden de sustituir el modo inmediato **antes** de medir si el contexto sale core. Log: `:241-247`, `glGetString(GL_VERSION)` + `GL_RENDERER` una sola vez, guardado por `gl_logged`. Es exactamente lo que la v1 pidió: un hueco declarado, no una suposición. |
| 10 | Cobertura del widget: 2 tests con sabotaje + módulo propio | **PARCIAL** | Módulo: **VERIFICADO** — `build.zig:143-176`, `terminal_widget_mod` con `ghostty-vt` + los 14 imports gobject + GL, `addTest` en `:175-176`; suites 7 → 8. Tests: existen dos (`:665`, `:690`). **El sabotaje no es real** — ver **B5**. |
| 11 | Tabla de citas completa de la sesión | **NO PRESENTADA** | No está en el árbol: el diff de `roadmap/designs/21-terminalview.md` no añade una sola fila a §«Firmas de API», y los cuerpos de los 3 commits son prosa. Las APIs nuevas de esta vuelta —`gobject.Object.virtual_methods.dispose.implement`, `gtk.Widget.signals.realize.connect`, `gtk.GLArea.signals.resize.connect`, `cairo.Surface.flush`, `glGetString`, `GL_BGRA`/`GL_ONE`/`GL_VERSION`/`GL_RENDERER`— siguen sin cita verificada. Los tres literales GL sí llevan comentario con `gl.h:línea` (`:45`, `:52`, `:57-58`), que es media cita. **Y la firma de `connect` es justamente la que rompe la compilación**: una tabla de citas hecha habría cazado esto antes que yo. Pídemela y la verifico con `sed -n` en la próxima vuelta. |

---

## Hallazgos nuevos de esta vuelta

### B4 — `deinit()` sobre memoria sin inicializar (regresión del arreglo 8)

`TerminalWidget.zig:108-115`:
```zig
const view_ptr = try alloc.create(TerminalView);
errdefer {
    view_ptr.deinit();          // ← corre con view_ptr.* == undefined
    alloc.destroy(view_ptr);
}
view_ptr.* = try TerminalView.init(io, alloc, num_cols, num_rows);
try view_ptr.initStream();
```

`alloc.create` devuelve memoria **sin inicializar**. Si `TerminalView.init` falla (OOM), el `errdefer`
llama `view_ptr.deinit()` sobre basura → `self.stream.deinit()`, `self.render_state.deinit()` y
`self.terminal.deinit()` sobre punteros inventados. La v1 señalaba aquí una **fuga**; la v2 la ha
convertido en **corrupción de memoria**. Un arreglo que empeora lo que arregla.

*Arreglo:* `errdefer alloc.destroy(view_ptr);` primero; tras `init` exitoso, un segundo
`errdefer view_ptr.deinit();`.

### B5 — Los dos tests del widget no sabotean nada

El diseño enmendado encarga (§Escenarios, 7º): *«Cuando se alimenta un byte y **se retira el
`queue_render`** → Entonces el frame no llega (sabotaje que prueba el eslabón)»*.

Lo entregado (`:690-717`) cuenta `frames_requested`, un contador **añadido para el test**
(`:78`, incrementado en `:139` *antes* de `glib.idleAdd`). Borrar la línea que de verdad importa —
`self.as(gtk.GLArea).queueRender()` en `onIdleQueueRender:146` — deja los dos tests **en verde**. El
sabotaje no toca el eslabón que dice probar.

El primer test (`:665-687`) llama `TerminalWidget.onResize(...)` **directamente**. Prueba la
aritmética del handler (200/10 = 20 cols, 900/15 = 60 rows, y que llega a `Terminal.resize`), lo cual
está bien y no es poco — pero **no prueba el cableado**, que es lo que el escenario 7 existe para
probar y lo que hoy está roto. El diseño ya lo admitía a medias («probado headless llamando al
handler»); la consecuencia es que la única red que quedaba para el cableado era `zig build`, y nadie
la miró.

Adicional: `var widget: TerminalWidget = undefined` en la pila (`:668`, `:693`) se pasa a
`glib.idleAdd` (`:140`) desde `widget.feed`. La fuente idle queda registrada en el contexto principal
apuntando a memoria de pila ya muerta cuando el test retorna. Hoy es inerte (ningún test itera un
main loop), pero es una mina para el primer test que lo haga.

### N1 — `initStream()` es un segundo paso obligatorio sin red

`TerminalView.init` deja `stream = undefined` (`:45`) y confía en que el llamante invoque
`initStream()` inmediatamente. El razonamiento es correcto y está bien documentado (`:52-55`), pero:
`feed` antes de `initStream` es UB, y `deinit` (`:59-63`) llama `self.stream.deinit()`
incondicionalmente — sobre `undefined` si `initStream` nunca corrió. B4 pisa exactamente ese camino.
*Sugerencia:* un `stream_ready: bool` comprobado en `deinit`, o devolver `*Self` desde un
`create(alloc)` que haga las dos cosas y no deje estado a medias.

### N2 — Dos reservas menores del pipeline de píxeles

- `glTexImage2D(:544-552)` pasa `GL_BGRA` también como **internalFormat**. `GL_BGRA` no es un
  internalFormat válido en GL estricto (lo son `GL_RGBA`/`GL_RGBA8`); GL legacy lo tolera, core lo
  rechaza. Se enreda con D4: si el contexto sale core, esta línea falla además del modo inmediato.
- La textura mide `@ceil(cell_h)` px de alto (`:546`) pero el quad mide `cell_h` con texcoords `0..1`,
  así que cada fila se comprime verticalmente en un factor `cell_h/⌈cell_h⌉`. Con `GL_NEAREST` eso es
  aliasing de hasta una línea de píxel por fila. *Arreglo:* `glTexCoord2f(_, cell_h/⌈cell_h⌉)` en los
  dos vértices inferiores. Cambio bueno respecto de la v1 (la deriva acumulada era peor), pero no
  está terminado.

### N3 — `TerminalView.renderFrame` es duplicación residual

La enmienda G1 dice: *«el widget… NO duplica feed/resize/count/lock»*, y se cumple para esos cuatro.
Pero `TerminalView.renderFrame:90-122` sigue conteniendo su propio `beginUpdate`/`endUpdate`/`clean`
+ `glViewport`/`glClearColor`/`glClear`, que es lo mismo que hace `onRender:250-282`, y **nadie la
llama** (`grep`: cero call sites fuera del propio archivo). Es el resto de la arquitectura de dos
implementaciones que G1 vino a eliminar. Bórrala: sus `extern "c" fn gl*` (`TerminalView.zig:17-20`)
se van con ella, y el módulo del núcleo deja de necesitar `linkSystemLibrary("GL")`.

---

## Lo que sí mejoró, y no debe perderse

La ronda no fue en balde. Ocho de los catorce arreglos están genuinamente hechos, y tres de ellos
eran los conceptualmente difíciles:

- **G1 cumplido en lo esencial.** El widget compone `?*TerminalView` (`:68`) y delega feed, resize,
  lock y estado VT. Una sola verdad sobre el contrato. La unificación se llevó por delante el
  spinlock, `widget_alloc` y `widget_io` sin dejar rastro — `grep` vacío en las tres.
- **A1 cerrado bien.** El `Stream` persistente respeta lo que `Terminal.zig:374-379` exige por
  escrito, y el comentario explica el porqué del orden (dirección final del `Terminal`), que es la
  parte que un lector futuro habría roto sin darse cuenta.
- **D4 resuelto como se pide en este repo:** un hueco declarado con las fuentes consultadas y su
  resultado negativo, más un instrumento (`GL_VERSION`/`GL_RENDERER` en el primer frame) para que el
  gate lea el dato en vez de suponerlo. Un hueco declarado es seguro; una suposición con forma de
  dato, no.
- **B1 y C3 eliminados de raíz**, no parcheados.
- **D1/D2/D3** aplicados con comentario que nombra el hallazgo que los originó.

---

## Para APROBAR

Bloqueantes:

1. **Que `zig build` pase.** Corregir el orden de parámetros de `onRealize` y `onResize` a
   `fn (*Self, …, ?*anyopaque)` según `gtk4.zig:56694`, o conectar con `self` como `user_data`.
   Verificar con `zig build && zig build test`, **los dos**, y pegar los dos exit codes.
2. **B4** — `errdefer alloc.destroy` antes; `errdefer view_ptr.deinit()` después del `init` exitoso.
3. **B5** — un test que falle si se borra `queueRender()` de `onIdleQueueRender`, y un test que
   construya el widget **por GObject** (`TerminalWidget.new()`) para que `defineClass` se analice.
   Ese segundo test es la red que faltaba: habría cazado el fallo de compilación.
4. **Arreglo 11** — la tabla de citas de la sesión, con `sed -n` línea por línea, incluyendo
   `signals.*.connect` y `virtual_methods.dispose.implement`. Pégamela y la verifico.

No bloqueantes:

5. **N1** — cerrar la ventana `init`/`initStream`.
6. **N2** — internalFormat `GL_RGBA8`; texcoord `cell_h/⌈cell_h⌉`.
7. **N3** — borrar `TerminalView.renderFrame` y sus `extern "c" fn gl*`.
8. Los `.?` de `ensureReady` a `orelse`.

Todo lo demás de la v1 queda cerrado.

---

**VEREDICTO v2: DENEGADO.** El árbol no compila (`zig build` exit 1, `TerminalWidget.zig:170`), y el
`zig build test` en verde lo esconde porque los tests fabrican el widget a mano y nunca instancian el
GObject. Ocho arreglos están bien hechos; el noveno —el cableado, que era el corazón de la v1— está
escrito pero roto, y uno (`errdefer`) empeoró. Ninguno de los cuatro bloqueantes es conceptual: son
una firma, un `errdefer`, un test que instancie el widget y una tabla de citas.

---
---

# ↓↓↓ HISTORIA — Auditoría v1 (primera vuelta, artefacto `403d377..14afbec`) ↓↓↓

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
