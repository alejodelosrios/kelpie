title: Attach externo (v0.1): abrir el agente con `omarchy launch or focus tui … herdr agent attach <pane> --takeover`
labels: type:feat,area:ui
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
En v0.1 no hay widget de terminal propio (llega en M2). Hyprland tiling + el terminal de Omarchy
dan un attach usable hoy: un click abre (o enfoca, si ya existe) una ventana con `herdr agent
attach`. Este camino se conserva después como "Abrir en Ghostty". Depende de #16, #17.

## Alcance
Entra: al enfocar un agente local: `omarchy launch or focus tui --app-id=io.github.alejodelosrios.kelpie.attach.<pane-id>
herdr agent attach <pane-id> --takeover`; verificar en `/usr/share/omarchy/bin/omarchy-launch-or-focus-tui`
la semántica exacta de `--app-id` y del or-focus (si no encaja, fallback documentado: `ghostty
--class=<app-id> -e herdr agent attach <pane-id> --takeover`); para remotos (M3): el mismo comando
con `ssh -t <target> herdr agent attach <pane-id> --takeover`; preferencia "Abrir agentes en el
terminal de Omarchy" (default on en M1, off tras #27); detach es `ctrl+b q` (documentar en la UI).
No entra: terminal embebido (#21+), attach de solo lectura (`herdr terminal session observe`).

## Criterios de aceptación
- [ ] Click en un agente abre una ventana del terminal de Omarchy con el pane attach en < 1 s; Hyprland la coloca junto a kelpie.
- [ ] Segundo click en el mismo agente enfoca la ventana existente en vez de abrir otra (or-focus por `app-id`).
- [ ] `ctrl+b q` cierra el attach y el agente sigue vivo en herdr.
- [ ] Si el `herdr` local no coincide en versión con el servidor (`protocol_mismatch`), kelpie muestra el error de `herdr status --json` (`restart_needed`) en vez de una ventana vacía.
- [ ] El argv se construye como array (test unitario), sin string de shell.

## Referencias
- `herdr agent attach --help`; `/usr/share/omarchy/bin/omarchy-launch-or-focus-tui`, `omarchy-launch-tui`.
- herdrm ejecuta `herdr agent attach '<paneID>' --takeover` (comportamiento, sin copiar).

## Skills
`omarchy-app`, `omarchy`, `herdr`.
