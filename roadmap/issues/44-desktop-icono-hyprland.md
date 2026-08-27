title: `.desktop`, icono hicolor y reglas de ventana Hyprland (Lua) documentadas
labels: type:feat,area:omarchy,area:pkg
milestone: M5 — Integración Omarchy
---
## Contexto
Aparecer en el lanzador de Omarchy es XDG puro: el shell usa `DesktopEntries` y abre con
`uwsm-app -- gtk-launch <id>.desktop`. La clase de ventana es el id de GApplication. Hyprland en
Omarchy 4 se configura en Lua. Depende de #13.

## Alcance
Entra: `data/io.github.alejodelosrios.kelpie.desktop` (`Name=kelpie`, `Exec=kelpie %u`,
`Icon=io.github.alejodelosrios.kelpie`, `Categories=Development;`, `StartupNotify=true`,
`Keywords=herdr;agents;terminal;`), icono SVG en `data/icons/hicolor/scalable/apps/` (+ `-symbolic`),
instalación en `build.zig` (`b.installFile` a `share/applications` y `share/icons/...`); sección en el
README con el snippet Lua para `~/.config/hypr/hyprland.lua`: `o.window("io.github.alejodelosrios.kelpie", { … })`
(workspace fijo, tamaño flotante opcional, `tag = "-default-opacity"` para opaco) y un atajo con
`omarchy launch or focus io.github.alejodelosrios.kelpie kelpie` siguiendo la sintaxis de
`/usr/share/omarchy/default/hypr/bindings/`.
No entra: escribir en `~/.config/hypr/` automáticamente, iconos por tema.

## Criterios de aceptación
- [ ] `zig build && zig build install --prefix ~/.local` deja kelpie en el lanzador de Omarchy y `gtk-launch io.github.alejodelosrios.kelpie.desktop` lo abre.
- [ ] `hyprctl clients -j | jq '.[].class'` muestra `io.github.alejodelosrios.kelpie`.
- [ ] El icono se ve en el lanzador con el tema Yaru activo (variante de color del tema).
- [ ] El snippet Lua del README aplicado a `hyprland.lua` + `hyprctl reload` mueve kelpie al workspace indicado.
- [ ] `desktop-file-validate` sin errores.

## Referencias
- `/usr/share/omarchy/shell/services/AppLibrary.qml:53-85`; `/usr/share/omarchy/default/hypr/apps/system.lua:1-11` (sintaxis `o.window`); `default/hypr/bindings/`.

## Skills
`omarchy-app`, `omarchy`.
