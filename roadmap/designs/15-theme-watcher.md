# Diseño — #15 Recarga del tema en vivo vigilando el directorio padre (con test)

> Aprobado por: orquestador fleet (wA:p1) vía `/kelpie-flow 15` · 2026-08-31 · con un cambio
> obligatorio incorporado: `ThemeWatcher.zig` va en `src/omarchy/`, no `src/ui/` (es el primero de
> la familia `area:omarchy` — #18, #42, #43, #46 aterrizan ahí también), y la tabla de citas usa
> rutas completas en vez de solo el nombre del archivo.

## Spec

`ThemeWatcher` vigila el **directorio** `$XDG_STATE_HOME/omarchy/current/` (o
`~/.local/state/omarchy/current/`) con `GFileMonitor` + `G_FILE_MONITOR_WATCH_MOVES`, porque
`omarchy-theme-set:291-296` reemplaza `current/theme` entero con `rm -rf` + `mv` — un watch sobre el
inode del archivo `kelpie.css` queda huérfano al primer cambio de tema.

**Archivos que se tocan** (territorio `ui-builder`, ambos ya arrendados a esta ola):
- `src/omarchy/ThemeWatcher.zig` (nuevo) — el watcher: genérico sobre una ruta de directorio, sin
  conocimiento del resto de Omarchy más allá de vivir en la carpeta de la familia `area:omarchy`
  (junto a #18 `Notify.zig`, #42 `status.json`, #43 `setup`, #46 no-molestar). La genericidad la da
  la firma `start(dir_path, on_reload, user_data)`, no el directorio. Expone `start(...)` / `deinit()`.
- `src/ui/app_shell.zig` — importa `src/omarchy/ThemeWatcher.zig` e instancia un
  `var theme_watcher: ThemeWatcher` a nivel de módulo (mismo patrón que
  `struct_provider`/`theme_provider`, línea 73-74: single-thread, sin sync); `onActivate` lo arranca
  una vez con la ruta de `current/` y un callback que llama a la `reloadTheme()` ya existente (línea
  237-239, que ya llama a `loadCss()` → `loadFromPath` con fallback a `loadFromString`, líneas
  246-273). El `test { }` de cierre (línea ~101 estilo `main.zig:101-104`) gana `_ = ThemeWatcher;`
  para que sus tests corran bajo `zig build test`.

**No toca `build.zig`.** Verificado: `main.zig` no camina `@import`s transitivamente para
descubrir tests (comentario propio en `main.zig:96-100`, confirmado contra Zig 0.16); los módulos
que sí se appendan al final de `build.zig` (`theme_css_mod`, `local_server_mod`, `events_mod`) lo
hacen porque **nadie los importa todavía**. `ThemeWatcher.zig` sí tiene consumidor desde este mismo
PR (`app_shell.zig`), así que sus tests viajan gratis vía el `test { _ = ThemeWatcher; }` que ya
existe en `app_shell.zig` importado por `main.zig` — sin tocar `build.zig`, sin cruce con el
`theme_css_mod` que arrienda #12 en paralelo.

**No entra**:
- Hooks (`omarchy hook install theme-set`) — #45.
- Watch de fontconfig — #22.
- Bus de eventos multi-listener para `themeChanged`: el "emitir `themeChanged`" del issue se resuelve
  como el propio callback `on_reload` que `ThemeWatcher` ya invoca — un puntero a función, no
  infraestructura de señal GObject. #26 (el único consumidor futuro) puede engancharse ahí cuando
  exista; no hay hoy un segundo suscriptor que justifique una lista de callbacks (YAGNI).
- Recorrer más de **un** nivel de ancestro cuando `current/` no existe al arrancar (ver "Riesgos").

## Firmas de API que se van a usar

Todas verificadas por el PM contra el mirror pinneado de `zig-gobject` 0.3.2 (mismo hash que usa
`build.zig.zon:15`). Raíz común de las rutas `gio2.zig`/`glib2.zig` de abajo:
`~/.cache/ghostty-build/src/zig-global-cache/p/gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3/src/`.

| API | Fuente (ruta completa`:línea`) | Verificada |
|---|---|---|
| `gio.File.newForPath(path: [*:0]const u8) *gio.File` | `.../src/gio2/gio2.zig:31863-31864` | ✅ (ya en uso, `app_shell.zig:289`) |
| `gio.File.monitorDirectory(file, flags, cancellable, error) ?*gio.FileMonitor` | `.../src/gio2/gio2.zig:32659-32660` | ✅ |
| `gio.FileMonitorFlags.flags_watch_moves` (bit `8`, `G_FILE_MONITOR_WATCH_MOVES`) | `.../src/gio2/gio2.zig:44740` | ✅ |
| `gio.FileMonitor.signals.changed.connect(monitor, ?*anyopaque, callback, data, .{})` — callback `fn(*gio.FileMonitor, *gio.File, ?*gio.File, gio.FileMonitorEvent, ?*anyopaque) callconv(.c) void` | `.../src/gio2/gio2.zig:8459-8471` | ✅ |
| `gio.FileMonitorEvent` — `.changed`, `.deleted`, `.created`, `.renamed`, `.moved_in`, `.moved_out` | `.../src/gio2/gio2.zig:42939-42950` | ✅ |
| `gio.File.getBasename(file) ?[*:0]u8` (owned, libera con `glib.free`) | `.../src/gio2/gio2.zig:32310-32311` | ✅ |
| `gio.File.queryExists(file, cancellable) c_int` | `.../src/gio2/gio2.zig:32881-32882` | ✅ (ya en uso, `app_shell.zig:291`) |
| `glib.timeoutAddOnce(interval_ms: c_uint, fn: *const fn(?*anyopaque) callconv(.c) void, data) c_uint` — dispara una vez, para el debounce | `.../src/glib2/glib2.zig:24427-24428` (tipo `SourceOnceFunc` en `.../src/glib2/glib2.zig:25660`) | ✅ |
| `glib.Source.remove(tag: c_uint) c_int` — cancela un timeout pendiente antes de que dispare | `.../src/glib2/glib2.zig:9913-9914` | ✅ |
| `glib.free(ptr: ?*anyopaque) void` | `.../src/glib2/glib2.zig:20178-20179` | ✅ |
| `glib.MainContext.default() *glib.MainContext` | `.../src/glib2/glib2.zig:5129-5130` | ✅ (solo para el test, bombear el loop) |
| `glib.MainContext.iteration(context: ?*glib.MainContext, may_block: c_int) c_int` | `.../src/glib2/glib2.zig:5311-5312` | ✅ (solo para el test) |
| `omarchy-theme-set` reemplaza el directorio entero (`rm -rf` + `mv`) | `/usr/share/omarchy/bin/omarchy-theme-set:291-293` (grep directo en la máquina) | ✅ |
| Contrato de dos `CssProvider` module-level + `loadFromPath`/fallback `loadFromString` que este issue recarga | `src/ui/app_shell.zig:73-74`, `241-273` | ✅ (código propio, ya leído) |

## Escenarios (Gherkin)

```gherkin
# Criterio 1 (obligatorio, test automatizado — el que el PM verifica en FASE 5)
Escenario: rm -rf + mv + echo tres veces seguidas produce tres recargas
  Dado un tmpdir con "current/theme/kelpie.css" y "current/theme.name"
  Y un ThemeWatcher arrancado sobre el directorio "current/" con un contador de recargas
  Cuando se simula, tres veces seguidas: "rm -rf current/theme", luego
    "mv current/next-theme current/theme", luego "echo x > current/theme.name"
  Entonces el contador de recargas llega a 3
  Y la última recarga lee el contenido nuevo de "current/theme/kelpie.css"
  Y el mismo test, ejecutado contra una implementación que vigila el ARCHIVO
    "current/theme/kelpie.css" en vez del directorio "current/", FALLA (queda huérfano tras el
    primer rm -rf) — así el test es el propio guardarraíl contra la regresión que #15 corrige.
```

```gherkin
# Criterio 2 (manual — requiere sesión Wayland real; QA lo guiona, el humano lo ejecuta)
Escenario: theme set ida y vuelta con kelpie abierto
  Dado kelpie abierto con un tema activo
  Cuando el humano ejecuta "omarchy theme set gruvbox" y luego "omarchy theme set <original>"
  Entonces toda la UI cambia en menos de 1 segundo, las dos veces, sin reiniciar kelpie
```

```gherkin
# Criterio 3 (manual — requiere ventana real para medir RSS; QA lo guiona, el humano lo ejecuta)
Escenario: 20 cambios de tema no acumulan monitores ni memoria
  Dado kelpie abierto con ThemeWatcher activo
  Cuando el humano hace 20 "omarchy theme set <tema>" seguidos (alternando entre 2-3 temas)
  Entonces el RSS del proceso se mantiene estable (sin crecimiento monótono)
  Y solo hay un GFileMonitor vivo en todo momento (un solo "start" nunca re-arma sin cancelar el anterior)
```

```gherkin
# Criterio 4 (mixto: el enganche es automatizable en tmpdir; la ausencia de crash con Omarchy
# real ausente es responsabilidad del propio findThemeCssPath ya existente, #14)
Escenario: directorio "current/" ausente al arrancar, aparece después
  Dado un tmpdir SIN "current/"
  Cuando se arranca el ThemeWatcher sobre esa ruta
  Entonces no hay crash y se loguea un warning
  Cuando "current/" se crea después (mkdir + archivos)
  Entonces el watcher engancha sobre el "current/" real sin reiniciar el proceso
  Y una recarga posterior (rm -rf + mv + echo) sigue produciendo un reload
```

## Riesgos y preguntas abiertas

- **Ancestro único, no recursivo.** Cuando `current/` no existe, el diseño vigila **un solo nivel**
  hacia arriba (`$XDG_STATE_HOME/omarchy/`) esperando el hijo `current` (evento `created` o
  `moved_in`), y al verlo re-arma sobre `current/` directamente. Si `omarchy/` **tampoco** existe
  (máquina sin Omarchy en absoluto, ni siquiera el directorio de estado), el watcher no engancha en
  absoluto — se limita a loguear el warning y quedar sin monitor activo hasta el próximo `start()`.
  El issue solo exige tolerar la ausencia de `current/`, no la de todo `$XDG_STATE_HOME/omarchy/`;
  documentado aquí como hueco declarado, no como caso cubierto.
- **No verificado en la fuente**: si `gio.File.monitorDirectory` sobre una ruta inexistente
  devuelve `null` (error) de forma consistente en el backend inotify de Linux, o si en algún caso
  devuelve un monitor "vacío" que nunca dispara. El doc-comment de `gio2.zig:8404-8408` solo dice
  "puede fallar si no hay soporte de monitoreo de directorios" — no dice qué pasa con una ruta que no
  existe. Apply debe verificarlo empíricamente en el test del criterio 4 (tmpdir sin `current/`):
  si `monitorDirectory` no devuelve `null` ahí, el fallback de ancestro-único de arriba nunca se
  ejercita y hay que ajustar el diseño antes de cerrar el issue, no asumir que sí falla.
- **Debounce de 100 ms compartido por evento, no por ráfaga acumulada**: cada evento relevante
  cancela el timer pendiente (`glib.Source.remove`) y arma uno nuevo de 100 ms — así una ráfaga de
  `rm -rf` + `mv` + `echo` en el mismo `theme set` colapsa en una sola recarga si los tres eventos
  llegan dentro de la ventana; si `omarchy-theme-set` tarda más de 100 ms entre pasos (variable con
  disco/CPU), el escenario del criterio 1 puede ver más de una recarga por ciclo de `theme set` en
  vez de las 3 exigidas (una por ciclo simulado, no una por evento). El test debe medir "al menos 3"
  con la última con contenido correcto si esto resulta ser el comportamiento real, o el número exacto
  si el debounce colapsa perfectamente cada ráfaga — a decidir en QA con el comportamiento medido,
  no supuesto.
