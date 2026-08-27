title: Recarga del tema en vivo vigilando el directorio padre (el tema se reemplaza con `rm -rf` + `mv`), con test
labels: type:feat,area:omarchy,risk:high
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
`omarchy-theme-set:292-293` hace `rm -rf current/theme && mv next-theme current/theme`: un watch
sobre el archivo `kelpie.css` queda apuntando a un inode muerto tras el primer cambio. Se vigila el
**directorio** `~/.local/state/omarchy/current/` y se reacciona a los movimientos. Depende de #14.

## Alcance
Entra: `src/omarchy/ThemeWatcher.zig` con `gio.File.monitorDirectory(WATCH_MOVES)` sobre
`$XDG_STATE_HOME/omarchy/current/`; filtro por nombre de hijo `theme` (eventos renamed / moved-in /
created / deleted) y `theme.name` (changed); debounce de 100 ms; acción: recargar el `CssProvider`
desde la ruta y emitir `themeChanged` para que #26 relea la paleta; tolerar que el directorio no
exista al arrancar (sin Omarchy → fallback, sin crash) y que aparezca después.
No entra: hooks (#45), watch de fontconfig (#22).

## Criterios de aceptación
- [ ] Test de integración en tmpdir: crear `current/theme/kelpie.css`, arrancar el watcher, simular `rm -rf theme; mv next-theme theme; echo x > theme.name` **tres veces seguidas** → tres recargas, la última con el contenido nuevo. Este test es obligatorio y debe fallar si se cambia a un monitor de archivo.
- [ ] Con kelpie abierto, `omarchy theme set gruvbox` y luego `omarchy theme set <original>`: toda la UI cambia en < 1 s las dos veces, sin reiniciar.
- [ ] 20 cambios de tema seguidos no acumulan monitores ni memoria (RSS estable; un solo `GFileMonitor` vivo).
- [ ] Directorio ausente al inicio → log warning; crearlo después → el watcher engancha sin reiniciar.

## Referencias
- Skill `omarchy-app` §1 "Cómo vigilar". `/usr/share/omarchy/bin/omarchy-theme-set:12-13, 291-296`.
- context7: GIO `g_file_monitor_directory`, `G_FILE_MONITOR_WATCH_MOVES`, `GFileMonitorEvent` (`RENAMED`, `MOVED_IN`).

## Skills
`omarchy-app`, `context7`.
