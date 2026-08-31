# Diseño — #16 Sidebar por urgencia: espacios y agentes, glifos de estado, filas de 28/30 px y hairlines

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-31

## Spec

`src/ui/sidebar.zig` (nuevo): un `gtk.ScrolledWindow` → `gtk.ListView` sobre
`gio.ListStore` de un GObject mínimo (`RowObject`), alimentado por un `*Store` (#12).
El sidebar **no habla con herdr**: recibe un `*Store`, se registra como `ChangeObserver`
y reconstruye su modelo cuando el Store cambia. `app_shell.zig` (#13) crea el `Store`,
sustituye su `gtk.Box` vacío por este widget, y conecta `focusAgent` de verdad.

**Archivos que se tocan** (territorio `ui-builder`, `area:ui`):
- `src/ui/sidebar.zig` — **nuevo**: todo el widget, el `RowObject`, el agrupado y los tests.
- `src/ui/app_shell.zig` — dueño del `Store`; monta el sidebar en el slot del split;
  `focusAgent` deja de ser costura muerta; flag `--demo-sidebar[=N]`; CSS de las clases nuevas.
- `src/main.zig` — **solo** dos líneas: reconocer `--demo-sidebar` y `_ = sidebar;` en el
  bloque `test {}` final (Zig no descubre tests por `@import` transitivo).

**No entra** (copiado del issue, más lo recortado por YAGNI):
- Drag & drop de espacios, renombrar, menús contextuales, dispositivos remotos (#34).
- **`gtk.SectionModel` / `setHeaderFactory`.** El issue pide "sección por dispositivo (solo
  `local` en M1)": con exactamente un dispositivo, la maquinaria de secciones no produce
  ni un píxel distinto de una fila-cabecera normal, y ningún criterio de aceptación la
  menciona (la "cabecera 42 px" del criterio 2 es la `adw.HeaderBar` que ya entregó #13).
  El dispositivo se dibuja como una fila más (`kind = .device`). #34, que es quien introduce
  el segundo dispositivo, es quien decidirá si necesita secciones de verdad.
- **El cableado en vivo a herdr** (`LocalServer.ensureRunning` + `client.Connection` para el
  `session.snapshot` inicial + `EventsClient` en su hilo + dispatcher a la main loop de GLib).
  No está en el "Entra" del issue, no aparece en ninguno de sus cinco criterios de aceptación,
  y es trabajo de otra forma (hilos, reconexión, ruta del socket, bootstrap del snapshot) con
  su propio Gherkin. El diseño de #12 lo dejó pendiente para "un issue de UI futuro" **sin
  nombrar a #16**. Se abre issue propio: **#81**, bloqueante de #20. Consecuencia declarada, no
  silenciada: **al mergear #16 la app sigue mostrando el sidebar vacío en uso normal**; lo que
  se puede ver y medir es `kelpie --demo-sidebar[=N]`.
- Espacios sin ningún agente: no se dibujan. El sidebar deriva su árbol de la lista de agentes
  (ver §Agrupado), así que un workspace vacío no tiene fila. Es un sidebar de agentes.

## Agrupado: por qué no hace falta API nueva en el Store

`Store.orderedAgents` (`src/model/Store.zig:538`) ya devuelve **todos** los agentes ordenados
por urgencia (`blocked > done > working > idle > unknown`, luego `revision` descendente) y cada
`Agent` lleva su `workspace_id` (`Store.zig:18-32`). Un `group-by` **estable** de esa lista
plana, respetando el orden de primera aparición de cada `workspace_id`, produce exactamente lo
que pide el issue **en una sola pasada, sin ordenar nada**:

- los espacios quedan ordenados por su agente más urgente → un agente que se bloquea arrastra
  a su espacio al primer lugar (criterio 1);
- dentro de cada espacio los agentes ya vienen por urgencia;
- el `agent_status` agregado del espacio **es** el status de su primer agente en la lista plana.

El nombre visible del espacio sale de `store.workspaces.getPtr(.{ .device_id, .workspace_id })`
(`Store.zig:89-94`, valor `types.WorkspaceInfo`); si no está en el mapa, se cae al `workspace_id`.

Filas resultantes, en orden: `.device` ("local"), y por cada espacio `.workspace` seguido de sus
`.agent`.

## Modelo de filas y propiedad de memoria

```zig
/// GObject mínimo: SOLO un índice a `Sidebar.rows`. Sin punteros propios, sin
/// finalize, sin duplicar strings — el dueño de los datos es el Sidebar.
const RowObject = extern struct {
    parent_instance: Parent,
    index: u32,
    pub const Parent = gobject.Object;
    pub const Class = extern struct {
        parent_class: Parent.Class,
        pub const Instance = RowObject;
    };
    pub const getGObjectType = gobject.ext.defineClass(RowObject, .{});
};
```

`Sidebar.rows` es un `std.array_list.Managed(Row)` propiedad del Sidebar, con `Row` = `{ kind,
status, title: [:0]u8, subtitle: ?[:0]u8, device: []u8, pane: []u8 }`, todo duplicado con el
`gpa` del Sidebar y liberado en `clearRows()`/`deinit()`. **`refresh()` construye la lista nueva
completa ANTES de liberar la vieja y antes de tocar el `gio.ListStore`**: si una duplicación
falla por OOM, el sidebar se queda con el modelo anterior intacto en vez de con uno a medias
(misma raíz que `lessons-learned.md` `#5`/`#8`: un literal con campo falible no es atómico).

`refresh()` repuebla el `gio.ListStore` con **un solo** `splice(0, n_viejo, nuevos, n_nuevo)`
(`gio2.zig:10414`), no con `removeAll` + N `append`: una sola emisión de `items-changed`, que es
lo que hace medible el "< 200 ms" del criterio 1 y lo que evita que la selección parpadee.
Tras el splice se restaura la selección buscando `(device, pane)` en `rows`.

```
ponytail: refresh() reconstruye el modelo entero en cada cambio del Store — O(n) por evento.
Con 200 agentes y el ritmo de eventos de herdr es irrelevante; si un día lo es, el upgrade es
diffear rows vieja/nueva y emitir splices parciales.
```

## Widgets, métricas y CSS

Un único `gtk.SignalListItemFactory` para las tres clases de fila; `bind` decide por
`row.kind`. Ninguna métrica ni color va en Zig salvo las alturas, que son el criterio 2:

| Fila | Altura | Clase CSS | Contenido |
|---|---|---|---|
| `.device` | 30 px | `kelpie-row-device` | label del nombre del dispositivo |
| `.workspace` | 30 px | `kelpie-row-workspace` | label + `AgentStatusGlyph` agregado |
| `.agent` | 28 px | `kelpie-row-agent` | título 13 medium + subtítulo 11.5 (`agente · cwd`) + glifo |

`AgentStatusGlyph` no es una clase GObject: es una función que puebla un `gtk.Box` contenedor de
ancho fijo. Criterio 3 ("el spinner solo existe mientras el estado es `working`, no hay widget
oculto girando") se cumple por construcción: `bind` **crea** el hijo que toca y `unbind` lo quita
con `gtk.Box.remove` (`gtk4.zig:3310`); `idle`/`unknown` no crean ninguno.

- `working` → `gtk.Spinner` (`gtk4.zig:44975`), 12×12 px, `setSpinning(1)`.
  ```
  ponytail: el periodo de rotación lo fija GTK (~1 s), no los 0,9 s del issue, y no es
  configurable por CSS. Ningún criterio de aceptación lo mide. Si alguna vez importa, el
  upgrade es un gtk.DrawingArea con su propio gtk.Widget.addTickCallback.
  ```
- `blocked` → `gtk.Label` con `󰀦` (Nerd Font), clase `kelpie-glyph-blocked`.
- `done` → `gtk.Label` con `󰄬`, clase `kelpie-glyph-done`.

Todo lo demás es CSS en `app_shell.zig` (mismo `kelpie_css` que ya existe, `app_shell.zig:60-63`),
**exclusivamente por `var(--…)`** — cero hexadecimales (ADR-0001 §5, criterio 4). Tokens usados,
todos ya definidos por #14 (`data/kelpie-fallback.css:29-39`): `--status-working`,
`--status-blocked`, `--status-done`, `--text-1`, `--text-2`, `--item-wash`,
`--item-wash-selected`, `--hairline`.

Los separadores de 1 px son `gtk.ListView.setShowSeparators(view, 1)` (`gtk4.zig:30125`) más
`row separator { min-height: 1px; background: var(--hairline); }` — sin widgets propios.

Criterio 5 (200 agentes, scroll fluido) lo da el `gtk.ListView` con factory: recicla los widgets
de fila por diseño. `setSingleClickActivate(view, 1)` (`gtk4.zig:30130`) hace que un click
seleccione **y** active en un gesto, que es lo que pide "click selecciona y dispara `focusAgent`".

## `--demo-sidebar[=N]`

Los criterios 1, 2 y 5 exigen mirar y medir un sidebar **poblado** con el inspector de GTK, y
tras el recorte de arriba nada lo puebla en uso normal. `--demo-sidebar[=N]` (por defecto N=4)
aplica al Store un `types.SessionSnapshot` sintético de N agentes repartidos en 2 espacios, todos
`idle`, y arma un temporizador único que a los 2 s pasa uno a `blocked` vía `Store.applyEvent`.
No es andamiaje especulativo: es el instrumento que los tres criterios necesitan, y el mismo que
QA guiona. Vive detrás del flag; el arranque normal no lo toca.

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Todas verificadas por el PM con `sed -n '<línea>p' <archivo>`,
una línea por invocación (`sed` imprime en orden de archivo, no de argumentos —
`lessons-learned.md`, Ola 3 M1 · "el instrumento del PM también falla").

Raíz de los bindings, la misma tarball/hash que declara `build.zig.zon`:
`$GOB = /home/alejodelosrios/.cache/ghostty-build/src/zig-global-cache/p/gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3/`

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `gobject.ext.defineClass(Instance, options) fn() callconv(.c) gobject.Type` | `$GOB/src/gobject2/ext.zig:171` | ✅ |
| `gobject.ext.newInstance(comptime T, properties) *T` | `$GOB/src/gobject2/ext.zig:1642` | ✅ |
| `gobject.ext.cast(comptime T, self) ?*T` | `$GOB/src/gobject2/ext.zig:1632` | ✅ |
| `gio.ListStore.new(item_type: usize) *gio.ListStore` | `$GOB/src/gio2/gio2.zig:10322` | ✅ |
| `gio.ListStore.append(store, item: *gobject.Object) void` | `$GOB/src/gio2/gio2.zig:10331` | ✅ |
| `gio.ListStore.removeAll(store) void` | `$GOB/src/gio2/gio2.zig:10394` | ✅ |
| `gio.ListStore.splice(store, position: c_uint, n_removals: c_uint, additions: [*]*gobject.Object, n_additions: c_uint) void` | `$GOB/src/gio2/gio2.zig:10414` | ✅ |
| `gio.ListModel.getNItems(list) c_uint` | `$GOB/src/gio2/gio2.zig:33959` | ✅ |
| `gtk.SingleSelection.new(model: ?*gio.ListModel) *gtk.SingleSelection` | `$GOB/src/gtk4/gtk4.zig:43221` | ✅ |
| `gtk.SingleSelection.setAutoselect(self, autoselect: c_int) void` | `$GOB/src/gtk4/gtk4.zig:43255` | ✅ |
| `gtk.SingleSelection.getSelected(self) c_uint` | `$GOB/src/gtk4/gtk4.zig:43241` | ✅ |
| `gtk.SingleSelection.setSelected(self, position: c_uint) void` | `$GOB/src/gtk4/gtk4.zig:43282` | ✅ |
| `gtk.SignalListItemFactory.new() *gtk.SignalListItemFactory` | `$GOB/src/gtk4/gtk4.zig:43133` | ✅ |
| `gtk.SignalListItemFactory.signals.{setup,bind,unbind,teardown}.connect(inst, T, cb, data, opts)`, `cb` recibe `p_object: *gobject.Object` | `$GOB/src/gtk4/gtk4.zig:43050` (`bind`), `:43073` (`setup`), `:43093` (`teardown`), `:43115` (`unbind`) | ✅ |
| `gtk.ListItem.getItem(self) ?*gobject.Object` | `$GOB/src/gtk4/gtk4.zig:29327` | ✅ |
| `gtk.ListItem.setChild(self, child: ?*gtk.Widget) void` | `$GOB/src/gtk4/gtk4.zig:29379` | ✅ |
| `gtk.ListItem.getPosition(self) c_uint` | `$GOB/src/gtk4/gtk4.zig:29333` | ✅ |
| `gtk.ListItem.setActivatable(self, activatable: c_int) void` | `$GOB/src/gtk4/gtk4.zig:29371` | ✅ |
| `gtk.ListView.new(model: ?*gtk.SelectionModel, factory: ?*gtk.ListItemFactory) *gtk.ListView` | `$GOB/src/gtk4/gtk4.zig:30060` | ✅ |
| `gtk.ListView.signals.activate.connect(...)`, `cb` recibe `p_position: c_uint` | `$GOB/src/gtk4/gtk4.zig:30039` | ✅ |
| `gtk.ListView.setShowSeparators(self, show: c_int) void` | `$GOB/src/gtk4/gtk4.zig:30125` | ✅ |
| `gtk.ListView.setSingleClickActivate(self, v: c_int) void` | `$GOB/src/gtk4/gtk4.zig:30130` | ✅ |
| `gtk.ScrolledWindow.new() *gtk.ScrolledWindow` | `$GOB/src/gtk4/gtk4.zig:40328` | ✅ |
| `gtk.ScrolledWindow.setChild(self, child: ?*gtk.Widget) void` | `$GOB/src/gtk4/gtk4.zig:40415` | ✅ |
| `gtk.ScrolledWindow.setPolicy(self, h: gtk.PolicyType, v: gtk.PolicyType) void`; `PolicyType.never = 2`, `.automatic = 1` | `$GOB/src/gtk4/gtk4.zig:40498`, `:73594` | ✅ |
| `gtk.Spinner.new() *gtk.Spinner` | `$GOB/src/gtk4/gtk4.zig:44975` | ✅ |
| `gtk.Spinner.setSpinning(self, spinning: c_int) void` | `$GOB/src/gtk4/gtk4.zig:44983` | ✅ |
| `gtk.Box.new(orientation: gtk.Orientation, spacing: c_int) *gtk.Box` | `$GOB/src/gtk4/gtk4.zig:3268` | ✅ |
| `gtk.Box.append(box, child: *gtk.Widget) void` | `$GOB/src/gtk4/gtk4.zig:3272` | ✅ |
| `gtk.Box.remove(box, child: *gtk.Widget) void` | `$GOB/src/gtk4/gtk4.zig:3310` | ✅ |
| `gtk.Label.new(str: ?[*:0]const u8) *gtk.Label` | `$GOB/src/gtk4/gtk4.zig:27215` | ✅ |
| `gtk.Label.setText(self, str: [*:0]const u8) void` | `$GOB/src/gtk4/gtk4.zig:27557` | ✅ |
| `gtk.Label.setXalign(self, xalign: f32) void` | `$GOB/src/gtk4/gtk4.zig:27613` | ✅ |
| `gtk.Label.setEllipsize(self, mode: pango.EllipsizeMode) void`; enum en `pango1.zig:5326` | `$GOB/src/gtk4/gtk4.zig:27430` | ✅ |
| `gtk.Widget.addCssClass(w, class: [*:0]const u8) void` | `$GOB/src/gtk4/gtk4.zig:56860` | ✅ |
| `gtk.Widget.removeCssClass(w, class: [*:0]const u8) void` | `$GOB/src/gtk4/gtk4.zig:57961` | ✅ |
| `gtk.Widget.setSizeRequest(w, width: c_int, height: c_int) void` | `$GOB/src/gtk4/gtk4.zig:58306` | ✅ |
| `gtk.Widget.setValign(w, align: gtk.Align) void`; `Align.center = 3` | `$GOB/src/gtk4/gtk4.zig:58347`, `:72441` | ✅ |
| `gtk.Widget.setVexpand(w, expand: c_int) void` / `setHexpand` | `$GOB/src/gtk4/gtk4.zig:58354` / `:58148` | ✅ |
| `gtk.Widget.setMarginStart/End/Top/Bottom(w, margin: c_int) void` | `$GOB/src/gtk4/gtk4.zig:58187` / `:58183` / `:58191` / `:58179` | ✅ |
| `Store.orderedAgents(self, allocator) !std.array_list.Managed(*const Agent)` | `src/model/Store.zig:538` | ✅ |
| `Store.addObserver(self, observer: ChangeObserver) !void` | `src/model/Store.zig:163` | ✅ |
| `Store.ChangeObserver{ ptr, onChangedFn, onTransitionFn }` | `src/model/Store.zig:122-134` | ✅ |
| `Store.applySnapshot(self, snapshot: types.SessionSnapshot) !void` / `applyEvent` | `src/model/Store.zig:171` / `:238` | ✅ |
| `Store.init(gpa) Store` / `deinit(self)` | `src/model/Store.zig:143` / `:153` | ✅ |
| `types.AgentStatus = enum { idle, working, blocked, done, unknown }` | `src/herdr/types.zig:9-14` | ✅ |
| `Agent.displayTitle(self) []const u8` | `src/model/Store.zig:33` | ✅ |
| `adw.OverlaySplitView.setSidebar(self, sidebar: ?*gtk.Widget)` (ya en uso) | `src/ui/app_shell.zig:147` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: cuatro agentes idle no dibujan nada
  Dado un Store con 4 agentes en estado idle repartidos en 2 espacios
  Cuando el sidebar refresca su modelo
  Entonces el modelo tiene 7 filas (1 device + 2 workspace + 4 agent)
  Y ninguna fila de agente ni de espacio lleva glifo
  Y ningún gtk.Spinner existe en el árbol de widgets

Escenario: un agente que se bloquea sube al primer lugar
  Dado un Store con 4 agentes idle, el agente A en el segundo espacio
  Cuando A pasa a blocked por un applyEvent
  Entonces el espacio de A es el primer espacio del modelo
  Y A es la primera fila de agente del modelo
  Y la fila de A y la de su espacio llevan el glifo de blocked
  Y el refresco completo tarda menos de 200 ms

Escenario: alturas y separadores exactos
  Dado kelpie --demo-sidebar corriendo en una sesión Wayland
  Cuando se mide con el inspector de GTK
  Entonces las filas de agente miden 28 px de alto
  Y las filas de espacio y de dispositivo miden 30 px
  Y la cabecera de la ventana mide 42 px
  Y los separadores miden 1 px

Escenario: el spinner no sobrevive al cambio de estado
  Dado una fila de agente en estado working con su gtk.Spinner
  Cuando el agente pasa a idle y la fila se re-bindea
  Entonces el contenedor del glifo no tiene ningún hijo
  Y no queda ningún gtk.Spinner girando oculto en esa fila

Escenario: cero color literal en el CSS de kelpie
  Dado el CSS que kelpie carga (kelpie_css + la hoja del tema)
  Cuando se buscan literales de color en las reglas de kelpie
  Entonces no aparece ningún hexadecimal ni rgb() en src/
  Y cada color de fila y de glifo se resuelve por var(--…)

Escenario: 200 agentes reciclan filas
  Dado kelpie --demo-sidebar=200
  Cuando se hace scroll de arriba abajo de la lista
  Entonces el número de widgets de fila creados es muy inferior a 200
  Y el scroll no salta

Escenario: el click enfoca al agente
  Dado un sidebar con agentes y single-click-activate
  Cuando se activa la fila del agente local/pane-3
  Entonces focusAgent recibe ("local", "pane-3")
  Y esa fila queda seleccionada
```

## Riesgos y preguntas abiertas

- **La app queda inerte tras este issue.** Recorte declarado arriba: sin el cableado a herdr, el
  sidebar solo se puebla con `--demo-sidebar`. Se abre issue propio: **#81**, bloqueante de #20.
- **Periodo del spinner**: GTK no expone el periodo de `gtk.Spinner` por CSS; se queda en el
  ~1 s de GTK en vez de los 0,9 s del issue. Ningún criterio lo mide. Anotado con `ponytail:`.
- **Nerd Font**: los glifos `󰀦` / `󰄬` dependen de que la `monospace` de fontconfig sea una Nerd
  Font. Omarchy la instala, pero si no lo fuera se vería un tofu. No se añade fallback en este
  issue (sería una decisión de fuente, `area:font`, #22).
- **RESUELTO en el gate visual (decisión del humano, 2026-08-31)**: el hueco de abajo se disparó.
  `setShowSeparators` pintaba de borde a borde tras **cada** fila y con **su** color, no con
  `--hairline`: medido sobre captura, pico `rgb(30,32,33)` donde el token da `rgb(16,17,18)` — el
  doble de brillo. Se quitó `setShowSeparators`; ahora hay hairline **solo entre grupos**, en las
  filas de espacio, y se inserta 12 px por lado con un `linear-gradient` en vez de un `margin`
  (un margen movería también el texto de la cabecera y lo desalinearía de las filas de agente).
  Medido después: pico `rgb(13,14,14)`, o sea el token. El criterio 2 pasa a leerse "hairline de
  1 px entre grupos", no "entre todas las filas".

- **Hueco declarado, no supuesto**: no se verificó en la fuente si `gtk.ListView.setShowSeparators`
  aplica el separador también entre la última fila de un espacio y la primera del siguiente, ni si
  el separador es un nodo `separator` estilable por CSS en GTK 4.20. Si el gate visual del
  criterio 2 muestra que no, la alternativa es un `border-bottom` de 1 px en las clases de fila —
  cambio de CSS, no de estructura.
