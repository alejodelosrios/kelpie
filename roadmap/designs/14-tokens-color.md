# Diseño — #14 Tokens de color: `kelpie.css.tpl` generado por Omarchy, variables de libadwaita y paleta `--term0..15`, cero hex en código

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-28 · rama `feature/14-tokens-color`

## Spec

kelpie no tematiza GTK por sí mismo: el color llega **siempre** desde una hoja CSS que genera el
motor de plantillas de Omarchy. Este issue entrega: (1) la plantilla `kelpie.css.tpl` que ese motor
rellena con los tokens del tema activo, (2) un CSS de fallback embebido en el binario (único lugar
del repo con hex permitido — es dato, no código) para cuando el usuario aún no instaló la
plantilla, (3) la carga en tiempo de ejecución de esa hoja (real o fallback) como un segundo
`gtk.CssProvider` sobre el mismo `gdk.Display`, y (4) un parser mínimo de líneas `--nombre: valor;`
sobre texto CSS, reutilizable por #26. La cabecera, el sidebar y el acento cambian de color solo
porque libadwaita ya lee esas variables (`--headerbar-bg-color`, `--sidebar-bg-color`,
`--accent-bg-color`, …) de su propio `:root`; kelpie no dibuja el color, solo lo declara.

**Archivos que se tocan** (todos `area:ui`/`area:omarchy` → territorio `ui-builder`; `data/` no
tenía dueño en la tabla de territorios de `CLAUDE.md` — se asigna aquí explícitamente a
`ui-builder`, por ser puramente datos de tematización, para no repetir el hueco de hotspot sin
dueño de #2):
- `data/themed/kelpie.css.tpl` (nuevo) — la plantilla, con la sintaxis literal `{{ token }}` /
  `alpha({{ token }}, N)` que Omarchy sustituye por `sed`. Contenido exacto: el que ya trae el
  cuerpo del issue #14 (bloques a/b/c: variables de libadwaita, tokens semánticos de kelpie, paleta
  `--term0..15`) — no se reinventa, se transcribe.
- `data/kelpie-fallback.css` (nuevo) — mismas variables que la plantilla, valores hex fijos (una
  paleta oscura neutra razonable). Se embebe en el binario con `@embedFile` (builtin de Zig, sin
  cambios entre versiones — no requiere cita del mirror): el hex vive en un archivo de datos, nunca
  en una constante de código Zig fuera de este archivo.
- `src/ui/app_shell.zig` — **solo** `kelpie_css` (líneas 16-20) y `loadCss()` (líneas 86-95): se
  añade un segundo `gtk.CssProvider` que carga `~/.local/state/omarchy/current/theme/kelpie.css`
  (o `$XDG_STATE_HOME/omarchy/current/theme/kelpie.css` si esa var existe) si el archivo existe, o
  si no, el fallback embebido, con `std.log.warn` en ese segundo caso. `kelpie_css` (estructura:
  alturas, tipografía) no cambia — el color no vive ahí, vive en el segundo provider. `run()` y
  `onActivate()` no se tocan (issue #17 los toma en la próxima ola).
- `src/ui/theme_css.zig` (nuevo) — `pub fn iterate(css: []const u8) Iterator` con
  `Iterator.next() ?CssVar{name, value}`: parser de declaraciones `--nombre: valor;` sobre un
  bloque CSS arbitrario. Sin dependencia de GTK — texto puro. Es lo que pide el criterio de
  aceptación "test del parser… (usado por #26)"; #26 no se implementa aquí.
- `build.zig` — **enmendado post-Apply** (no estaba en la lista original de este diseño; añadido
  aquí para que el contrato refleje lo mergeado, per hallazgo del auditor): dos líneas, sin tocar
  `build.zig.zon` ni el commit pinneado de ghostty. (1) `exe_mod.addAnonymousImport("kelpie-fallback-css",
  .{ .root_source_file = b.path("data/kelpie-fallback.css") })` — necesario para que
  `@embedFile("kelpie-fallback-css")` en `app_shell.zig` alcance un archivo fuera de `src/`; se probó
  empíricamente que `zig build` funciona igual sin tocar `build.zig.zon` (revertido tras probarlo).
  (2) un `addTest` independiente para `src/ui/theme_css.zig` (mismo patrón que `vt_spike_mod`, ya
  existente en el archivo): sin él, sus tests no son alcanzables por ningún `@import` desde el
  módulo raíz y `zig build test` no los compila ni corre — lo encontró QA.

**No entra** (copiado del issue, más lo recortado por YAGNI):
- Recarga en vivo del `GFileMonitor` al cambiar de tema (#15): hoy la hoja se lee una vez en
  `loadCss()`, al arrancar.
- Componentes que consuman los tokens semánticos de kelpie (`--status-working`, `--device-tint-*`,
  …) más allá de declararlos en la plantilla (#36).
- Instalación/copiado automático de la plantilla a `~/.config/omarchy/themed/` (#43): en este issue
  se hace a mano como parte del criterio de aceptación (`cp` + `omarchy theme set`), no hay código
  de instalación.
- El propio #26 (lo que sea que use el parser): esto solo entrega la función y su test.

## Firmas de API que se van a usar

Todas verificadas con `sed -n` sobre la misma tarball que ya usa `build.zig.zon`
(`gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`, ya usada como fuente en el diseño de
#13) y sobre la stdlib de Zig instalada (`/usr/lib/zig/std/`, versión confirmada `0.16.0` vía
`zig env`). Ninguna de memoria.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `gtk.CssProvider.new() *gtk.CssProvider` | `.../src/gtk4/gtk4.zig:11900-11901` | ✅ (ya en uso en el propio `app_shell.zig:88`) |
| `gtk.CssProvider.loadFromPath(p: *CssProvider, path: [*:0]const u8) void` | `.../src/gtk4/gtk4.zig:11924-11925` | ✅ |
| `gtk.CssProvider.loadFromString(p: *CssProvider, s: [*:0]const u8) void` | `.../src/gtk4/gtk4.zig:11937-11938` | ✅ (ya en uso) |
| `gtk.StyleContext.addProviderForDisplay(display, provider, priority: c_uint) void` | `.../src/gtk4/gtk4.zig:46220-46221` | ✅ (ya en uso) |
| `gtk.STYLE_PROVIDER_PRIORITY_APPLICATION` (= 600) | `.../src/gtk4/gtk4.zig:76694` | ✅ (ya en uso) |
| `gio.File.newForPath(path: [*:0]const u8) *gio.File` | `.../src/gio2/gio2.zig:31863-31864` | ✅ |
| `gio.File.queryExists(file: *File, cancellable: ?*gio.Cancellable) c_int` | `.../src/gio2/gio2.zig:32881-32882` | ✅ |
| `gio.File` implementa `gobject.Object` (unref con `gobject.Object.unref`) | `.../src/gio2/gio2.zig:29903-29905` (`Prerequisites = [_]type{gobject.Object}`) | ✅ |
| `std.c.getenv(name: [*:0]const u8) ?[*:0]u8` | `/usr/lib/zig/std/c.zig:10719` | ✅ |
| `std.fmt.bufPrintZ(buf, fmt, args) BufPrintError![:0]u8` | `/usr/lib/zig/std/fmt.zig:606` | ✅ |
| `std.fs.max_path_bytes` (alias de `std.Io.Dir.max_path_bytes`) | `/usr/lib/zig/std/fs.zig:14` | ✅ |
| `std.mem.indexOf(comptime T, haystack, needle) ?usize` (alias `find`) | `/usr/lib/zig/std/mem.zig:1414,1419` | ✅ |
| `std.mem.indexOfScalarPos(comptime T, slice, start, value) ?usize` (alias `findScalarPos`) | `/usr/lib/zig/std/mem.zig:1237,1241` | ✅ |
| `std.mem.trim(comptime T, slice, values_to_strip) []const T` | `/usr/lib/zig/std/mem.zig:1202` | ✅ |
| `std.log.warn(fmt, args) void` | `/usr/lib/zig/std/log.zig:153-156` | ✅ |
| `@embedFile("path")` devuelve `*const [N:0]u8` (sentinel `0`, coerciona a `[*:0]const u8`) | comprobado empíricamente: `zig run` sobre un archivo de 5 bytes → `type=*const [5:0]u8`, `data[len]==0` | ✅ (builtin del lenguaje, no del mirror) |
| Override de color de libadwaita en `:root` (`--accent-bg-color`, `--window-bg-color`, `--headerbar-bg-color`, `--sidebar-bg-color`, `--view-bg-color`, `--popover-bg-color`, `--error-color`, …) | context7 `/websites/gnome_pages_gitlab_gnome_libadwaita_doc_1-latest` → `css-variables.html` (secciones "Overriding Adwaita UI Colors", "Window Colors", "Header Bar Colors", "Sidebar Colors", "Popovers Colors", "Error Colors") | ✅ |
| Sintaxis de plantilla Omarchy `{{ token }}` / `alpha(<hex>, N)` | skill `omarchy-app` §1, contrastada contra `/usr/share/omarchy/default/themed/ghostty.conf.tpl` y `hyprland-preview-share-picker.css.tpl` (leídos en esta sesión) | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: la plantilla se resuelve sin tokens sin sustituir
  Dado que `data/themed/kelpie.css.tpl` está copiado a `~/.config/omarchy/themed/kelpie.css.tpl`
  Cuando se ejecuta `omarchy theme set <tema-activo>`
  Entonces `~/.local/state/omarchy/current/theme/kelpie.css` existe
  Y `grep -c '{{' ~/.local/state/omarchy/current/theme/kelpie.css` devuelve `0`

Escenario: kelpie usa los colores del tema activo (catppuccin)
  Dado el tema `catppuccin` aplicado y `kelpie.css` generado
  Cuando kelpie arranca
  Entonces la cabecera, el sidebar y el acento muestran los colores de `catppuccin`
    (captura de pantalla adjunta al PR)

Escenario: kelpie usa los colores del tema activo (gruvbox)
  Dado el tema `gruvbox` aplicado y `kelpie.css` generado
  Cuando kelpie arranca
  Entonces la cabecera, el sidebar y el acento muestran los colores de `gruvbox`
    (captura de pantalla adjunta al PR)

Escenario: sin kelpie.css, arranca con el fallback y avisa, sin crash
  Dado que `~/.local/state/omarchy/current/theme/kelpie.css` no existe (renombrado temporalmente)
  Cuando kelpie arranca
  Entonces el proceso no crashea
  Y el log contiene un `warn` mencionando el fallback
  Y la ventana se pinta con los colores de `data/kelpie-fallback.css`

Escenario: cero hexadecimales en el código fuente
  Dado el árbol `src/` tras este cambio
  Cuando se ejecuta `grep -rnE '#[0-9a-fA-F]{3,8}\b' src/`
  Entonces no devuelve ninguna línea

Escenario: el parser de variables CSS extrae nombre y valor
  Dado un bloque CSS de ejemplo con varias declaraciones `--nombre: valor;` (incluida alguna con
    espacios irregulares y una función `alpha(...)` como valor)
  Cuando se itera con `theme_css.iterate(css)`
  Entonces cada llamada a `.next()` devuelve el par `{name, value}` en el orden del texto
  Y al agotar las declaraciones devuelve `null`
```

Los tres primeros escenarios (captura con tema real, y el de "sin `kelpie.css`") requieren ventana
Wayland real — no los ejecuta QA en el fleet, se escalan al humano con guion concreto en FASE 6. Los
dos últimos son tests Zig normales (`grep` en CI / `zig build test`).

## Riesgos y preguntas abiertas

- La paleta exacta del fallback (`data/kelpie-fallback.css`) es una elección de diseño visual, no
  una firma de API: se propone una paleta oscura neutra (fondo `#1e1e2e`-ish); el humano puede pedir
  ajustarla en revisión sin que eso reabra el diseño.
- El criterio "cero hex en `src/`" se computa con `grep` sobre `src/` — `data/kelpie-fallback.css`
  vive fuera de `src/` a propósito, exactamente como dice el issue ("único lugar con hex
  permitido").
- No se verificó en máquina que `omarchy-theme-set-templates` efectivamente lea
  `~/.config/omarchy/themed/*.tpl` con este tema/versión exacta de Omarchy instalada — la skill lo
  documenta y es fuente de verdad, pero el escenario 1–3 (con ventana real) es también la
  verificación empírica de que el pipeline de Omarchy hace lo que la skill dice.
