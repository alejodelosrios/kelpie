# Diseño — #13 App shell GTK4/libadwaita: ventana con split sidebar/contenido, estado vacío, `--version`

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-28 · rama `feature/13-app-shell`

## Spec

Levantar el esqueleto visual de kelpie: una `adw.Application` con id
`io.github.alejodelosrios.kelpie` que abre una `adw.ApplicationWindow` de 1100×700 con
`adw.ToolbarView` (cabecera 42 px) envolviendo un `adw.OverlaySplitView` (sidebar 260 px fijo,
colapsable con `Ctrl+B`); contenido central = estado vacío (`gtk.Label` "Sin agentes"/"No agents"
a 28 px light, sin iconos ni botones); barra de estado inferior de 24 px vacía. `kelpie --version`
imprime la versión y sale 0 sin abrir ventana.

**Archivos que se tocan:**
- `src/ui/app_shell.zig` (nuevo) — `pub fn run() u8`: construye la `adw.Application`, conecta
  `activate`, arma el árbol de widgets, registra el shortcut de sidebar. Territorio `ui-builder`.
- `src/main.zig` — añade el flag `--version` (imprime y retorna antes del resto) y cambia la rama
  `else` (sin flags) para llamar `app_shell.run()` en vez de imprimir nombre+versión. **Hotspot de
  `core-builder`** en general, pero en esta ola el único otro issue abierto que toca `src/herdr/`
  (#8) se limita explícitamente a `src/herdr/client.zig` + `README.md` — no toca `src/main.zig`
  (confirmado en `gh issue view 8`, sección "Alcance": "Entra, todo dentro de
  `src/herdr/client.zig`"). Con el lease del hotspot libre en esta ventana, y el resto del issue
  siendo puramente `area:ui`, lo hace `ui-builder` en un solo pase en vez de secuenciar
  core→verificar→commitear→ui para un wiring de 4 líneas. No hay cambio a `build.zig` ni
  `build.zig.zon`: `gobject`/`adw`/`gtk`/`gio`/`gdk` ya están importados en `exe_mod` desde #3.

**No entra** (copiado del issue, más lo recortado por YAGNI):
- Filas del sidebar (#16), colores del tema (vienen del CSS generado de #14, hoy stylesheet solo
  fija alturas y tipografía, cero hexadecimales — ADR-0001 §5), persistencia de tamaño de ventana.
- i18n real: el criterio solo pide el string correcto por locale. Se resuelve con un chequeo simple
  de `LANG`/`LC_ALL` (`std.process.getEnvVarOwned` vía `init.environ_map.get`) — si empieza con
  `es`, "Sin agentes"; si no, "No agents". Sin framework de traducción (YAGNI).
- Persistir el estado de `show-sidebar` entre sesiones: cada arranque inicia expandido.

## Firmas de API que se van a usar

Ninguna se escribe de memoria. Todas verificadas con `sed -n` sobre el tarball `gobject` ya
extraído por el propio `zig build` de este repo en
`/home/alejodelosrios/.cache/ghostty-build/src/zig-global-cache/p/gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3/`
— misma tarball/hash que declara `build.zig.zon` (`gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`),
no una API recordada. `src/ui/spike_b.zig` (#3) ya usa el mismo patrón `adw.Application` +
`gio.Application.signals.activate.connect` + `gobject.ext.as`.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `adw.Application.new(app_id: ?[*:0]const u8, flags: gio.ApplicationFlags) *adw.Application` | `src/adw1/adw1.zig:3247` | ✅ |
| `gio.Application.signals.activate.connect(app, T, cb, data, opts)` | `src/gio2/gio2.zig:773` | ✅ |
| `gio.Application.run(app: *Application, argc: c_int, argv: ?[*][*:0]u8) c_int` (patrón ya usado en `spike_b.zig:26`) | `src/ui/spike_b.zig:26` | ✅ |
| `adw.ApplicationWindow.new(app: *gtk.Application) *adw.ApplicationWindow` | `src/adw1/adw1.zig:3365` | ✅ |
| `adw.ApplicationWindow.setContent(self, content: ?*gtk.Widget) void` (`adw_application_window_set_content`) | `src/adw1/adw1.zig:3411` | ✅ |
| `gtk.Window.setDefaultSize(w, width, height)` | `src/gtk4/gtk4.zig:59394` | ✅ |
| `gtk.Window.setTitle(w, title: ?[*:0]const u8)` | `src/gtk4/gtk4.zig:59526` | ✅ |
| `gtk.Window.present(w)` | `src/gtk4/gtk4.zig:59315` | ✅ |
| `adw.ToolbarView.new() *adw.ToolbarView` | `src/adw1/adw1.zig:19045` | ✅ |
| `adw.ToolbarView.addTopBar(self, widget: *gtk.Widget)` | `src/adw1/adw1.zig:19053` | ✅ |
| `adw.ToolbarView.setContent(self, content: ?*gtk.Widget)` | `src/adw1/adw1.zig:19134` | ✅ |
| `adw.HeaderBar.new() *adw.HeaderBar` | `src/adw1/adw1.zig:7692` | ✅ |
| `adw.OverlaySplitView.new() *adw.OverlaySplitView` | `src/adw1/adw1.zig:10806` | ✅ |
| `adw.OverlaySplitView.setSidebar(self, sidebar: ?*gtk.Widget)` | `src/adw1/adw1.zig:10911` | ✅ |
| `adw.OverlaySplitView.setContent(self, content: ?*gtk.Widget)` | `src/adw1/adw1.zig:10865` | ✅ |
| `adw.OverlaySplitView.setMinSidebarWidth(self, width: f64)` / `setMaxSidebarWidth` | `src/adw1/adw1.zig:10895` / `:10886` | ✅ |
| `adw.OverlaySplitView.setSidebarWidthUnit(self, unit: adw.LengthUnit)`, `adw.LengthUnit.px = 0` | `src/adw1/adw1.zig:10936`, `:23681` | ✅ |
| `adw.OverlaySplitView.setShowSidebar(self, show: c_int)` / `getShowSidebar(self) c_int` | `src/adw1/adw1.zig:10907` / `:10838` | ✅ |
| `gtk.Label.new(str: ?[*:0]const u8) *gtk.Label` | `src/gtk4/gtk4.zig:27215` | ✅ |
| `gtk.Widget.addCssClass(w, class: [*:0]const u8)` | `src/gtk4/gtk4.zig:56860` | ✅ |
| `gtk.Widget.setHalign`/`setValign(w, align: gtk.Align)` | `src/gtk4/gtk4.zig:58115` / `:58347` | ✅ |
| `gtk.Box.new(orientation, spacing) *gtk.Box`, `gtk.Box.append(box, child)` | `src/gtk4/gtk4.zig:3268`, `:3272` | ✅ |
| `gtk.Widget.setSizeRequest(w, width, height)` | `src/gtk4/gtk4.zig:58306` | ✅ |
| `gtk.CssProvider.new()`, `.loadFromString(provider, css: [*:0]const u8)` | `src/gtk4/gtk4.zig:11900`, `:11937` | ✅ |
| `gtk.StyleContext.addProviderForDisplay(display, *gtk.StyleProvider, priority: c_uint)`, `STYLE_PROVIDER_PRIORITY_APPLICATION = 600` | `src/gtk4/gtk4.zig:46220`, `:76694` | ✅ |
| `gdk.Display.getDefault() ?*gdk.Display` | `src/gdk4/gdk4.zig:1934` | ✅ |
| `gtk.ShortcutTrigger.parseString(s: [*:0]const u8) ?*gtk.ShortcutTrigger` | `src/gtk4/gtk4.zig:42282` | ✅ |
| `gtk.CallbackAction.new(callback: gtk.ShortcutFunc, data, destroy) *gtk.CallbackAction` | `src/gtk4/gtk4.zig:4983` | ✅ |
| `gtk.ShortcutFunc = *const fn(*gtk.Widget, ?*glib.Variant, ?*anyopaque) callconv(.c) c_int` | `src/gtk4/gtk4.zig:76288` | ✅ |
| `gtk.Shortcut.new(trigger: ?*gtk.ShortcutTrigger, action: ?*gtk.ShortcutAction) *gtk.Shortcut` | `src/gtk4/gtk4.zig:41860` | ✅ |
| `gtk.ShortcutController.new()`, `.addShortcut(self, *gtk.Shortcut)` | `src/gtk4/gtk4.zig:42093`, `:42109` | ✅ |
| `gtk.Widget.addController(w, *gtk.EventController)` — `ShortcutController.Parent = gtk.EventController` (cast vía `gobject.ext.as`, patrón ya usado en `spike_b.zig:22,26,31,34,37...`) | `src/gtk4/gtk4.zig:56850`, `:42048` | ✅ |
| `--version` sale por el mismo camino que hoy imprime nombre+versión (`src/main.zig:41`, rama `else` existente) | `src/main.zig:40-42` | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: la ventana abre con la clase de aplicación correcta
  Dado que Hyprland está corriendo
  Cuando ejecuto `kelpie` sin argumentos
  Entonces `hyprctl clients -j` reporta una ventana con `class` igual a
    "io.github.alejodelosrios.kelpie"

Escenario: Ctrl+B colapsa y expande el sidebar
  Dado que kelpie está abierto con el sidebar visible
  Cuando presiono Ctrl+B
  Entonces el sidebar se colapsa con la animación por defecto de `adw.OverlaySplitView`
  Y al presionar Ctrl+B de nuevo el sidebar se expande

Escenario: estado vacío sin agentes
  Dado que kelpie abre sin agentes conectados
  Cuando se renderiza la vista central
  Entonces solo se ve el texto "Sin agentes" (o "No agents" según `LANG`) a 28 px
  Y no hay iconos ni botones en esa vista

Escenario: --version no abre ventana
  Dado un shell con kelpie en PATH
  Cuando ejecuto `kelpie --version`
  Entonces imprime la versión y el proceso sale con código 0
  Y no se abre ninguna ventana GTK

Escenario: inspector GTK sin warnings
  Dado kelpie corriendo con `GTK_DEBUG=interactive`
  Cuando abro el inspector
  Entonces no hay warnings de CSS ni de layout en la salida de stderr
```

## Riesgos y preguntas abiertas

- El criterio de aceptación "42 px" para la cabecera y "24 px" para la barra de estado se logra con
  `gtk.CssProvider` fijando `min-height` en clases CSS propias (`.kelpie-headerbar`,
  `.kelpie-statusbar`), sin ningún literal de color — cumple ADR-0001 §5. No hay API de libadwaita
  para fijar la altura de `AdwHeaderBar` por código (`top-bar-height` es de solo lectura).
- El criterio "GTK_DEBUG=interactive sin warnings" no se puede verificar de forma automática en
  CI (headless); queda como gate de QA en sesión Wayland real (FASE 6 del flow).
- No hay API de gobject para leer `LANG` vía GLib en el tarball revisado con ese nombre exacto —
  se usa `std.process` (ya disponible, sin nueva dependencia) leyendo `init.environ_map`.
