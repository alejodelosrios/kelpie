title: Flatpak (manifest `io.github.alejodelosrios.kelpie`)
labels: type:feat,area:pkg,later
milestone:
---
## Contexto
Opcional. Omarchy instala desde AUR; Flatpak amplía a otras distros, pero el sandbox complica el
socket de herdr, `ssh` y `omarchy notification send`. Solo tras 1.0 y con demanda real.

## Criterios de aceptación
- [ ] `flatpak-builder` construye; kelpie ve `~/.config/herdr/herdr.sock` y puede lanzar `ssh` (permisos documentados).

## Skills
`zig-libghostty`.
