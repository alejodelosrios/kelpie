title: Kitty graphics en TerminalView (decodificador PNG vía `sys`)
labels: type:feat,area:render,later
milestone:
---
## Contexto
`ghostty-vt` soporta el protocolo, pero exige registrar un decodificador PNG en `sys` y pintar
texturas. Con Pango/GSK el pintado es `gtk_snapshot_append_texture`. Útil para agentes que muestran
imágenes; fuera del camino crítico.

## Criterios de aceptación
- [ ] `kitty +kitten icat foto.png` dentro de kelpie muestra la imagen en la celda correcta y se desplaza con el scrollback.

## Skills
`zig-libghostty`.
