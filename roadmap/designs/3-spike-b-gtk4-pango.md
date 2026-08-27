# Diseño — #3 Spike B — ventana GTK4 vía zig-gobject y rejilla de texto Pango/GSK a ≥60 fps en Wayland

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-27 · rama `feature/3-spike-b-gtk4-pango`

## Spec

Añadir la dependencia `gobject` (misma tarball/hash que Ghostty) y levantar una `adw.Application`
con dos ventanas: (1) una con un widget propio que en su vfunc `snapshot` pinta una rejilla de
200×60 celdas — texto aleatorio monoespaciado con Pango/GSK, avances de glifo forzados al ancho de
celda, fondo por celda y atributos bold/underline — redibujando la rejilla completa cada frame vía
un tick callback, con un contador de fps en stderr; (2) una segunda con `gtk.GLArea` que solo crea
contexto y limpia a un color, como comprobación mínima del plan B (`GtkGLArea` + GL) si el plan A
no sostiene 60 fps.

**Archivos que se tocan** (`core-builder`; `build.zig`/`build.zig.zon` son hotspot suyo):
- `build.zig.zon` — nueva entrada `.dependencies.gobject` (`.lazy = true`, tarball y hash del issue).
- `build.zig` — `b.lazyDependency("gobject", ...)` + mapeo de imports idéntico a
  `SharedDeps.zig:713-731`; nuevo ejecutable o modo del binario existente para lanzar el spike
  (p. ej. flag `--spike-b`, siguiendo el patrón `--vt-info` de `src/main.zig` del spike A).
- `src/main.zig` — bajo la flag, construye la `adw.Application`, la ventana de la rejilla y la
  ventana del `GtkGLArea`; imprime el veredicto de fps a stderr.
- `src/ui/grid_widget.zig` (nuevo) — la subclase de `gtk.Widget` con el vfunc `snapshot`. Va en
  `src/ui/` porque es terreno de `ui-builder` (`area:ui`), aunque el issue también lleve
  `area:render`: no hay renderer de `ghostty-vt` involucrado, es un widget GTK puro.
- `.github/workflows/ci.yml` — deps del runner `gtk4 libadwaita pango`; el job no abre ventana
  (Wayland/GDK_DEBUG=frames/fps reales se corren y anotan a mano, fuera de CI).

**No entra:** `ghostty-vt`, PTY, entrada de teclado, CSS de tema, filas sucias (spike C, #4). El
binario del spike no persiste como modo permanente de `kelpie`; es una prueba desechable de M0.

## Firmas de API que se van a usar

Ninguna se escribe de memoria. El módulo `gobject` es una dependencia **lazy** — no está
materializada en el repo hasta que `zig build` la fetchea — así que las firmas se verificaron
descargando la tarball pinneada del propio issue (`gobject-2026-07-28-36-1.tar.zst`, hash
`gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`) y ejecutando `sed -n` sobre el
árbol extraído (`ghostty-gobject-0.10.0-2026-07-28-36-1/`). Es la misma tarball y hash que fetcheará
el Apply — no una API distinta "recordada".

| API | Fuente (`archivo:línea` dentro del tarball pinneado) | Verificada |
|---|---|---|
| Mapeo de imports gobject (`adw`,`gdk`,`gio`,`glib`,`glibunix`,`gobject`,`gtk`,`xlib`) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/build/SharedDeps.zig:713-731` | ✅ |
| `adw.Application.new(app_id: ?[*:0]const u8, flags: gio.ApplicationFlags) *adw.Application` | `src/adw1/adw1.zig:3247-3248` | ✅ |
| `gio.Application.signals.activate.connect(app, T, cb, data, opts)` | `src/gio2/gio2.zig:769-784` | ✅ |
| `adw.ApplicationWindow.new(app: *gtk.Application) *adw.ApplicationWindow` | `src/adw1/adw1.zig:3365-3366` | ✅ |
| `gtk.Window.setDefaultSize/setChild/present` | `src/gtk4/gtk4.zig:59394-59395`, `:59345-59346`, `:59315-59316` | ✅ |
| `gtk.Widget.setSizeRequest(w: *Widget, width: c_int, height: c_int)` | `src/gtk4/gtk4.zig:58306-58307` | ✅ |
| Patrón de subclase (`extern struct`, `gobject.ext.defineClass`, `Class.parent`, `classInit`) | `/home/alejodelosrios/.cache/ghostty-build/src/ghostty/src/apprt/gtk/class/window.zig:34-45,2271-2280` | ✅ |
| `gtk.Widget.virtual_methods.snapshot.implement(class, &fn(*Instance, *gtk.Snapshot) callconv(.c) void)` | `src/gtk4/gtk4.zig:56132-56141` | ✅ |
| `gtk.Widget.addTickCallback(widget, TickCallback, data, notify) c_uint` / `TickCallback = fn(*Widget, *FrameClock, ?*anyopaque) callconv(.c) c_int` | `src/gtk4/gtk4.zig:56898-56900`, `:76334-76335` | ✅ |
| `gtk.Widget.createPangoContext(widget) *pango.Context` / `getPangoContext` | `src/gtk4/gtk4.zig:57004`, `:57387` | ✅ |
| `gtk.Snapshot.appendColor(snapshot, color: *const gdk.RGBA, bounds: *const graphene.Rect)` | `src/gtk4/gtk4.zig:43647-43648` | ✅ |
| `gtk.Snapshot.appendCairo(snapshot, bounds: *const graphene.Rect) *cairo.Context` | `src/gtk4/gtk4.zig:43638-43639` | ✅ |
| `graphene.Rect.init(r, x, y, w, h) *graphene.Rect` | `src/graphene1/graphene1.zig:1526-1527` | ✅ |
| `gdk.RGBA{ f_red, f_green, f_blue, f_alpha: f32 }` | `src/gdk4/gdk4.zig:7816-7825` | ✅ |
| `pango.itemize(context, text: [*:0]const u8, start, length, attrs: *AttrList, cached_iter) *glib.List` (una `PangoItem` por run; un run contiguo preserva ligaduras) | `src/pango1/pango1.zig:6409-6410` | ✅ |
| `pango.shape(text, length, analysis: *const pango.Analysis, glyphs: *pango.GlyphString) void` | `src/pango1/pango1.zig:6603-6604` | ✅ |
| `pango.Item.f_analysis.f_font: ?*pango.Font` (fuente ya resuelta por `itemize`, se usa para dibujar y para forzar avances) | `src/pango1/pango1.zig:4093-4101`, `:2411-2429` | ✅ |
| `pango.GlyphInfo.f_geometry.f_width: pango.GlyphUnit` (avance en unidades Pango, `PANGO_SCALE`=1024/px — se sobreescribe a `cell_width_px * 1024` por glifo tras `shape`) | `src/pango1/pango1.zig:3744-3753` | ✅ |
| `pangocairo.showGlyphString(cr: *cairo.Context, font: *pango.Font, glyphs: *pango.GlyphString)` | `src/pangocairo1/pangocairo1.zig:314-315` | ✅ |
| `pango.FontDescription.new/setFamily/setAbsoluteSize/setWeight` (`pango.Weight.bold = 700`) | `src/pango1/pango1.zig:3155-3156,3321-3322,3304-3305,3454-3455,5829-5842` | ✅ |
| `gtk.GLArea` (widget de instancia directa, sin subclase) + `gtk.GLArea.signals.render.connect(area, T, fn(*GLArea,*gdk.GLContext,T) callconv(.c) c_int, data, opts)` | `src/gtk4/gtk4.zig:21013`, `:21125-21138` | ✅ |
| `gobject.ext.newInstance(T, properties)` — para instanciar el widget propio sin plantilla `.ui` | `src/gobject2/ext.zig:1642` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: la ventana abre en Wayland con el renderer por defecto y con ngl
  Dado el binario compilado con la dependencia gobject fetcheada
  Cuando se ejecuta en Hyprland sin GSK_RENDERER y luego con GSK_RENDERER=ngl
  Entonces ambas corridas abren la ventana sin crash
  Y se anota en el issue #3 qué ocurre con GSK_RENDERER=vulkan (puede fallar; se documenta, no bloquea)

Escenario: 60 fps redibujando las 12.000 celdas cada frame durante 10 segundos
  Dado la ventana de la rejilla abierta con el tick callback activo
  Cuando se mide con GDK_DEBUG=frames o el contador propio de stderr durante 10 s
  Entonces la media es ≥ 60 fps y ningún frame individual supera 33 ms
  Y los números se pegan en el issue #3

Escenario: los glifos caen exactamente en su columna
  Dado una fila de 200 'M' y una fila de 200 'i' en la rejilla, cada glifo con avance forzado a cell_width
  Cuando se renderizan con pango.shape + geometry.width sobreescrito y pangocairo.showGlyphString
  Entonces ambas filas terminan exactamente en el mismo píxel de borde derecho

Escenario: las ligaduras de JetBrains Mono aparecen en texto contiguo
  Dado una celda con el texto "->" y otra con "!=" dentro de un mismo run (mismo estilo, sin cortar el string en itemize)
  Cuando pango.itemize agrupa esos caracteres en un único PangoItem y pango.shape los da a HarfBuzz
  Entonces el glyph string resultante tiene menos glifos que caracteres de entrada (la ligadura se fusionó)

Escenario: plan B viable — GtkGLArea crea contexto y limpia a un color
  Dado la segunda ventana con un gtk.GLArea
  Cuando se realiza (signal "realize") y se emite "render"
  Entonces gdk.GLContext.makeCurrent no falla y el área se ve pintada del color de limpieza elegido

Escenario: veredicto escrito en el issue
  Dado los resultados de fps, alineación de columna y ligaduras
  Cuando se comparan contra la tabla de aborto del ADR-0001 §4
  Entonces el issue #3 queda con un comentario "Pango/GSK" o "plan B GL" y su justificación
```

## Riesgos y preguntas abiertas

- **Enlace de GL para la ventana plan B**: `gtk.GLArea::render` limpia con llamadas GL crudas
  (`glClearColor`/`glClear`); no hay binding de esas funciones en el tarball `gobject` (no es
  wrapper GDK, es OpenGL puro). Se declaran como `extern "c" fn` en `src/main.zig` y se linkea
  `exe.linkSystemLibrary("GL")` en `build.zig` — **no es una dependencia nueva del zig-pkg**, es una
  librería del sistema que Mesa/GTK ya requieren en tiempo de ejecución. Riesgo: el runner de CI no
  tiene `libGL` de desarrollo instalada; si `zig build` (solo compila, no ejecuta ventanas) falla en
  el link, se anota como hueco de CI, no bloquea el spike (el criterio se verifica en la máquina).
- **`GSK_RENDERER=vulkan`**: el issue solo pide anotar qué pasa, sin criterio de éxito — puede no
  estar disponible en esta máquina (Mesa sin ICD Vulkan); se documenta el resultado tal cual salga.
- El hash de `.gobject` en `build.zig.zon` es el que ya trae el issue; no se recalcula con
  `zig fetch --save`, se copia literal (evita depender de red en el Apply para el hash — solo la
  descarga del tarball necesita red, igual que `ghostty` en #2).
- La rejilla de 12.000 celdas se reconstruye por completo cada frame (peor caso a propósito, es lo
  que el issue pide medir) — no hay contrato de filas sucias aquí porque ese es el spike C (#4); no
  se optimiza el shaping por fila aunque en un renderer real de kelpie sí haría falta.
