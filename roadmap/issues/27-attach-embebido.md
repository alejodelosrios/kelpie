title: Attach embebido: la vista de agente corre el attach de herdr en TerminalView y reemplaza a Ghostty externo
labels: type:feat,area:ui,area:pty
milestone: M2 — Terminal embebido
---
## Contexto
Cierra el círculo de M2: el click en un agente del sidebar abre su terminal dentro de kelpie. El
comando exacto de attach y su comportamiento (pane existente, salir sin matar al agente) quedaron
verificados en #5 y #19. Depende de #19, #23, #24, #25, #26.

## Alcance
Entra: `AttachView` con un `TerminalView` por agente enfocado que corre `herdr agent attach <pane-id>
--takeover` (local: `HERDR_SOCKET_PATH` si el dispositivo tiene socket explícito; remoto:
`ssh -t <target> herdr agent attach <pane-id> --takeover`, así el binario remoto coincide con su
servidor y no hay `protocol_mismatch`); detach `ctrl+b q`; cabecera 42 px con título del agente, glifo
de estado y dispositivo; botón "Abrir en Ghostty" que conserva el camino externo (#19); al cerrar la
vista se cierra el attach, nunca el agente; reutilización de la vista al volver al mismo agente.
No entra: splits (#38), varios attach simultáneos visibles.

## Criterios de aceptación
- [ ] Click en un agente → su pane aparece en < 500 ms con el estado actual (no solo lo nuevo).
- [ ] Escribir en la vista llega al agente (se ve en la sesión de herdr); `Ctrl+C` no mata el agente, solo lo que herdr defina para attach.
- [ ] Cambiar de agente y volver conserva el scrollback local de la vista.
- [ ] Cerrar kelpie con attach abierto deja el agente vivo en herdr (`herdr agent list` lo muestra igual).
- [ ] Un agente remoto (#30) se ataca por el mismo camino y el título muestra el dispositivo.
- [ ] Preferencia "Abrir agentes en Ghostty externo" mantiene el comportamiento de #19 para quien lo prefiera.

## Referencias
- #5, #19 (comando de attach verificado), #30 (túnel).
- `~/.cache/…/herdrm-fork/Sources/HerdrM/TerminalView.swift` solo como referencia de comportamiento (sin copiar código).

## Skills
`zig-libghostty`, `herdr` (requiere `HERDR_ENV=1`).
