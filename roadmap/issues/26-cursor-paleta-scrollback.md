title: Cursor, paleta del tema (`--term0..15`), claro/oscuro y scrollback en TerminalView
labels: type:feat,area:render
milestone: M2 — Terminal embebido
---
## Contexto
El terminal debe verse como el resto de Omarchy: misma paleta que `ghostty.conf` del tema. Los
colores llegan por el CSS generado (#14) y cambian en vivo con el tema (#15). Depende de #21, #14.

## Alcance
Entra: leer de `kelpie.css` las custom properties `--term0..--term15`, `--term-bg`, `--term-fg`,
`--term-cursor`, `--term-selection-bg/fg` (parser de líneas `--nombre: #rrggbb;` con test) y
aplicarlas al `Terminal`/renderer; releer al recargar tema; colores 24-bit y de paleta 256 desde SGR;
estilos de cursor por DECSCUSR (bloque, barra, subrayado) sin parpadeo; scrollback: rueda /
`Shift+PgUp/PgDn` desplazan el viewport, cualquier tecla vuelve abajo; indicador discreto de
"estás en el historial".
No entra: parpadeo del cursor, temas por terminal, transparencia propia (la da Hyprland).

## Criterios de aceptación
- [ ] `omarchy theme set gruvbox` con kelpie abierto: la paleta del terminal cambia en < 1 s sin reiniciar (los 16 colores, fondo, cursor y selección); restaurar el tema al terminar.
- [ ] `printf '\e[38;2;255;0;0mR\e[0m'` pinta rojo puro; `tput setaf 3` usa `--term3`.
- [ ] `printf '\e[6 q'` cambia el cursor a barra; `\e[2 q` a bloque.
- [ ] `seq 1 5000` y luego `Shift+PgUp` muestra líneas anteriores; escribir vuelve al final.
- [ ] Test del parser de custom properties con un CSS de ejemplo (incluye líneas irrelevantes y comentarios).

## Referencias
- `/usr/share/omarchy/default/themed/ghostty.conf.tpl` (mapeo canónico 0..15).
- Plantilla `kelpie.css.tpl` (#14). `src/lib_vt.zig` (`CursorStyle`, `color`).

## Skills
`zig-libghostty`, `omarchy-app`.
