title: App shell GTK4/libadwaita: ventana con split sidebar/contenido, estado vacío, `--version`
labels: type:feat,area:ui
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
El esqueleto visual sobre el que caen sidebar (#16), tema (#14) y attach (#19). Depende de #7, #3.

## Alcance
Entra: `adw.Application` con id `io.github.alejodelosrios.kelpie`; `adw.ApplicationWindow` +
`adw.OverlaySplitView` (sidebar 260 px, colapsable con `Ctrl+B`), `adw.ToolbarView` con cabecera
de 42 px; contenido inicial = estado vacío: texto a 28 px light ("Sin agentes" / "No agents" según
locale) y nada más; barra de estado inferior de 24 px; `kelpie --version`; tamaño inicial 1100×700.
No entra: filas del sidebar, colores (vienen del CSS de #14), persistencia de tamaño.

## Criterios de aceptación
- [ ] `kelpie` abre en Hyprland con clase `io.github.alejodelosrios.kelpie` (`hyprctl clients -j`).
- [ ] `Ctrl+B` colapsa/expande el sidebar con la animación por defecto de libadwaita.
- [ ] Sin agentes la vista central solo muestra el texto de 28 px; no hay iconos ni botones.
- [ ] `kelpie --version` imprime la versión y sale 0 sin abrir ventana.
- [ ] Inspector GTK (`GTK_DEBUG=interactive`) sin warnings de CSS ni de layout.

## Referencias
- Spike B (#3) para el arranque de `adw.Application` en Zig; `src/apprt/gtk/application.zig` de Ghostty.
- context7: libadwaita `AdwOverlaySplitView`, `AdwToolbarView`, `AdwApplicationWindow`.

## Skills
`zig-libghostty`, `context7`.
