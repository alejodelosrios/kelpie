title: Hooks opcionales `theme-set` y `font-set` que avisan a kelpie por GApplication
labels: type:feat,area:omarchy
milestone: M5 — Integración Omarchy
---
## Contexto
El watcher de directorio (#15) y el de fontconfig (#22) ya cubren los cambios; los hooks son el
canal oficial de Omarchy y sirven de red de seguridad (p. ej. si el estado vive en otra ruta).
Se instalan solo con `kelpie setup --hooks`. Depende de #15, #17, #22.

## Alcance
Entra: `data/hooks/kelpie-theme-set` y `data/hooks/kelpie-font-set` (bash, 5 líneas): ejecutan
`kelpie reload-theme` / `kelpie reload-font` y salen 0 aunque kelpie no esté corriendo; acciones
`reload-theme` y `reload-font` en la app (misma ruta que el `command-line` de #17); instalación vía
`omarchy hook install <tipo> <script>` (copia a `~/.config/omarchy/hooks/<tipo>.d/`).
No entra: tocar `~/.config/omarchy/hooks/theme-set` (archivo suelto, es de otras herramientas).

## Criterios de aceptación
- [ ] Con kelpie cerrado, `omarchy theme set <x>` no imprime `Hook failed`.
- [ ] Con kelpie abierto y el watcher deshabilitado a propósito (flag de debug), el hook recarga el tema igual.
- [ ] `ls ~/.config/omarchy/hooks/theme-set.d/` muestra `kelpie-theme-set` con modo 755; el archivo suelto `theme-set` queda intacto (`sha256sum` antes/después).

## Referencias
- `/usr/share/omarchy/bin/omarchy-hook:13-28`, `omarchy-hook-install:18-29`, `omarchy-theme-set:339`, `omarchy-font-set:78`.

## Skills
`omarchy-app`, `omarchy`.
