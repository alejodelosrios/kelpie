title: Splits dentro de la vista de attach (y solo ahí)
labels: type:feat,area:ui
milestone: M4 — Acabado visual
---
## Contexto
Hyprland ya hace tiling entre ventanas; dentro de la vista de un agente sí tiene sentido abrir un
shell auxiliar al lado (p. ej. para probar lo que el agente hizo). Cualquier tiling fuera de
`AttachView` es scope creep y se rechaza. Depende de #27.

## Alcance
Entra: `Ctrl+Shift+D` divide `AttachView` en dos con `gtk.Paned` (horizontal; `Ctrl+Shift+E`
vertical), el nuevo panel corre `$SHELL` en el `cwd` del agente (si herdr lo expone) y **recibe el
teclado solo cuando el usuario lo pide** (lección de herdrm: "only ⌘D hands the keyboard to the
split shell, not every rebuild"); cerrar el shell cierra el split; máximo un nivel de anidación.
No entra: splits en el sidebar o entre agentes, guardar layouts, tabs.

## Criterios de aceptación
- [ ] Split, escribir en el shell, cerrar con `exit`: el attach sigue intacto y con el foco.
- [ ] Al llegar un evento que redibuja el sidebar, el foco del teclado NO salta al split.
- [ ] Un intento de dividir por tercera vez no hace nada (log debug).
- [ ] El shell del split arranca en el `cwd` del agente cuando `agent.list` lo incluye.

## Referencias
- `SplitContainer.swift` y el commit `fix(terminal): only ⌘D hands the keyboard…` del fork (comportamiento).

## Skills
`zig-libghostty`.
