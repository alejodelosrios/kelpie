---
name: omarchy-app
description: Contrato de "app nativa de Omarchy" destilado y verificado en Omarchy 4.0.0.alpha — rutas de temas y la trampa del reemplazo de directorio, plantillas `.tpl` y sus tokens, `omarchy notification send --exec`, plugin de barra Quickshell, hooks, Hyprland en Lua, lanzador y empaquetado. Úsala en todo issue con `area:omarchy`, `area:ui` (tokens) o `area:pkg`, y antes de tocar `~/.config/omarchy/`, `~/.config/hypr/`, `.desktop` o la barra.
---

# kelpie como app de Omarchy

**Regla dura:** `/usr/share/omarchy/` se **lee** (es la documentación real) y jamás se escribe: lo
pisa cada `omarchy update`. Todo lo del usuario va a `~/.config/omarchy/` y `~/.config/hypr/`.
El paquete (PKGBUILD) no puede escribir en `$HOME`: la instalación de usuario la hace `kelpie setup`.

Fuente de verdad para cualquier duda: los scripts en `/usr/share/omarchy/bin/` y
`/usr/share/omarchy/shell/README.md`. Cuando algo de aquí no cuadre con la máquina, gana la máquina.

## 1. Temas

### Pipeline (omarchy-theme-set, omarchy-theme-set-templates)

1. `omarchy theme set <nombre>` copia el tema a `~/.local/state/omarchy/current/next-theme/`.
2. `omarchy-theme-set-templates` procesa `~/.config/omarchy/themed/*.tpl` **primero** y luego
   `/usr/share/omarchy/default/themed/*.tpl`; escribe `next-theme/<basename sin .tpl>` solo si no
   existe ya (el archivo del tema gana; el primero que escribe gana). Solo si hay `colors.toml`.
   Son las **únicas dos** carpetas de plantillas: no hay ruta system-wide para terceros.
3. `omarchy-theme-set:292-293`: `rm -rf current/theme && mv next-theme current/theme`.
   **Reemplazo de directorio entero** → un watch sobre el inode de `current/theme/kelpie.css`
   queda huérfano al primer cambio.
4. Después: escribe `current/theme.name`, IPC al shell (`applyTheme`), scripts de retint en
   paralelo (`omarchy-restart-terminal` hace `killall -SIGUSR2 ghostty`), `omarchy-hook theme-set <nombre>`.

### Cómo vigilar (lo que kelpie hace)

- `GFileMonitor` sobre el **directorio** `~/.local/state/omarchy/current/` con `G_FILE_MONITOR_WATCH_MOVES`.
- Reaccionar a eventos cuyo hijo sea `theme` (renamed/moved-in/created/deleted) o `theme.name`
  (changed); debounce ~100 ms; releer `current/theme/kelpie.css`.
- Test obligatorio: en un tmpdir, simular `rm -rf theme; mv next-theme theme; echo x > theme.name`
  y comprobar que se recarga. Es el bug que ya costó horas con otra herramienta.
- Complemento opcional: `omarchy hook install theme-set <script>` → `~/.config/omarchy/hooks/theme-set.d/<script>`
  (copia, chmod 755; recibe el nombre del tema). El archivo suelto `hooks/theme-set` pertenece a
  otras herramientas (aquí, omazed): nunca se toca.

### Plantilla `kelpie.css.tpl` (en `~/.config/omarchy/themed/`)

Sustitución literal por `sed`; sin condicionales. Formas por token: `{{ accent }}` → `#rrggbb`,
`{{ accent_strip }}` → `rrggbb`, `{{ accent_rgb }}` → `r,g,b`. Funciones: `{{ mix a b 35% }}`,
`mix_strip`, `mix_rgb`. **No hay alpha**: se hace en CSS con `alpha(var(--x), 0.06)` o `color-mix()`.
Un token mal escrito queda literal en la salida (revisar el archivo generado).

Tokens (58, `omarchy-theme-color --file <colors.toml> --all`):
`mode theme_type accent selection muted cursor background dark_background darker_background
lighter_background foreground dark_foreground light_foreground bright_foreground
selection_background selection_foreground red yellow orange green cyan blue magenta purple brown
bright_red bright_yellow bright_green bright_cyan bright_blue bright_magenta bright_purple
color0..color15` + alias `bg dark_bg darker_bg lighter_bg fg dark_fg light_fg bright_fg`.

Paleta del terminal, mapeo canónico de Omarchy (`default/themed/ghostty.conf.tpl`):
`0=background 1=red 2=green 3=yellow 4=blue 5=magenta 6=cyan 7=foreground 8=muted 9..14=bright_*
15=bright_foreground`, `cursor=bright_foreground`, selección = `selection_background/foreground`.

Mapeo semántico obligatorio (rol de herdrm → token; alfas de herdrm medidas en su Theme.swift):

| Rol | Token / expresión CSS |
|---|---|
| accent / accentWash | `accent` / `alpha(accent, .12)` (oscuro .14) |
| working | `blue` (bright_blue en oscuro) |
| blocked / warning | `yellow`; si el tema trae `orange`, `orange` |
| done / success | `green` |
| danger | `red` |
| text → textSecondary → textTertiary → textGhost | `bright_foreground` → `foreground` → `dark_foreground` → `muted` |
| contentBackground / terminalBackground / statusBarBackground | `background` / `dark_background` / `lighter_background` |
| itemWash / itemWashSelected | `alpha(foreground, .06)` / `.07` |
| hairline / sidebarBorder | `alpha(foreground, .06–.08)` / `muted` |
| claro vs oscuro | `mode` |

Variables de libadwaita que la hoja redefine en `:root` (doc: libadwaita `css-variables.html`):
`--accent-bg-color --accent-color --window-bg-color --window-fg-color --view-bg-color --view-fg-color
--headerbar-bg-color --headerbar-fg-color --sidebar-bg-color --sidebar-fg-color --card-bg-color
--popover-bg-color --dialog-bg-color --success-color --warning-color --error-color`.
Claro/oscuro lo aplica libadwaita solo: Omarchy fija `org.gnome.desktop.interface color-scheme`.

Regenerar tras editar la plantilla: `omarchy theme set "$(< ~/.local/state/omarchy/current/theme.name)"`.

### Fuente

fontconfig es la fuente de verdad: `omarchy font set` escribe `~/.config/fontconfig/fonts.conf`
poniendo la familia elegida al frente de `monospace`. kelpie pide `monospace` a Pango y sigue el
cambio; para el cambio en vivo, vigilar ese archivo o instalar hook `font-set` (recibe la familia).
`omarchy font current` solo sirve para mostrar el nombre.

## 2. Notificaciones

El daemon `org.freedesktop.Notifications` es Quickshell (`omarchy-shell`). Una acción de libnotify
muere con su emisor; la acción que sobrevive es el hint `omarchy-exec-argv` que emite:

```
omarchy notification send --app-name kelpie -g <glifo> -u critical|normal -r <id-numérico> -p \
  "<headline>" "<descripción>" --exec kelpie focus <device-id>/<pane-id>
omarchy notification dismiss "<substring del headline>"
```

- `--exec` va **al final** y consume el resto de la línea como argv; se ejecuta como parámetros
  posicionales de bash (`Util.qml:57-64`). Nunca se concatena texto de agentes o rutas en un string.
- `--app-name` por defecto es `omarchy-action`, que **salta no-molestar** y marca la toast efímera.
  kelpie pasa siempre `--app-name kelpie`; el usuario que activó DND no ve toasts.
- `-r` es **numérico**: la primera vez se envía con `-p`, se guarda el id por (device, pane) y se
  reenvía con `-r <id>` para no apilar toasts del mismo agente.
- `-u critical` solo para bloqueado; `normal` para terminado. `-t` en ms.
- `dismiss` es substring case-sensitive sobre los popups visibles: el headline lleva un marcador
  estable por agente.

## 3. Plugin de barra (Quickshell 0.3.1)

- Directorio `~/.config/omarchy/plugins/<id>/` con `manifest.json` en la raíz; **el nombre del
  directorio es el id** (reverse-DNS, p. ej. `alejodelosrios.kelpie`). Schema: `shell/README.md`
  ("Installing a third-party plugin") y `shell/services/PluginRegistry.qml`.
- `kinds: ["bar-widget"]`, `entryPoints.barWidget: "BarWidget.qml"`, `barWidget.defaultSection`.
- QML raíz `BarWidget` (de `qs.Ui`) con `moduleName`; propiedades inyectadas `bar`, `settings`,
  `moduleName`; `bar.run(cmd)`, `bar.foreground/urgent`, `BarIconButton { onPressed(button) }`.
  Ejemplos mínimos: `shell/plugins/bar/widgets/Spacer.qml`, `Microphone.qml`, `SystemUpdate.qml`.
- Datos: `FileView { path; watchChanges: true; onFileChanged: reload(); onLoaded: parse(text()) }`.
  `text()` está **rancio** dentro de `onFileChanged`: siempre `reload()` y leer en `onLoaded`
  (`Commons/Color.qml:242-252`). Un `IpcHandler { target }` permite `omarchy-shell <target> <método>`.
- Guardar cualquier archivo bajo `~/.config/omarchy/plugins/` recarga el código en caliente.
- Activar/colocar: `omarchy plugin enable <id> --section right`, `omarchy bar move <id> --section right`.
  `shell.json` es del usuario: se edita con esos comandos, nunca se reemplaza (no hay deep-merge).
- Regla estética: el widget es **invisible** cuando no hay agentes bloqueados (`visible: count > 0`).

## 4. Hyprland (Lua), lanzador, paquete

- Hyprland 0.56 con `configProvider: lua`. Reglas del usuario al final de `~/.config/hypr/hyprland.lua`:
  `o.window("io.github.alejodelosrios.kelpie", { ... })`. La clase de ventana es el id de GApplication.
  Omarchy aplica opacidad por defecto vía tag; para opaco: `{ tag = "-default-opacity" }`.
- `.desktop`: XDG estándar. El paquete lo instala en `/usr/share/applications/`; el lanzador de
  Omarchy (Quickshell `DesktopEntries`) lo ve y lo abre con `uwsm-app -- gtk-launch <id>.desktop`.
  Para un atajo: `omarchy launch or focus <patrón-de-clase> <comando>`.
- Icono: gsettings `icon-theme` lo fija el tema (`icons.theme`, variantes Yaru). El `.desktop`
  referencia un icono por nombre instalado en `hicolor`.
- `omarchy pkg aur add kelpie` instala desde AUR; `omarchy hook install theme-set <script>` instala hooks.
- Comandos existentes verificados: `omarchy notification send|dismiss`, `omarchy font current|list|set`,
  `omarchy bar move|put|set`, `omarchy plugin add|enable|validate|list`, `omarchy restart shell`,
  `omarchy toggle notification silencing`, `omarchy pkg aur add`. No existe `omarchy launch <app>` genérico.
