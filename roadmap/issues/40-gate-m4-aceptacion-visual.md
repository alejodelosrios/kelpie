title: Gate M4 — prueba de aceptación visual: retematizar en vivo sin un solo color fuera de sitio
labels: type:docs
milestone: M4 — Acabado visual
---
## Contexto
La UI no está terminada hasta que pasa esto. Depende de #36, #37, #38, #39, #26.

## Criterios de aceptación
- [ ] Con kelpie abierto (sidebar con agentes de 2 dispositivos, búsqueda abierta, attach con split), `omarchy theme set catppuccin` y luego `omarchy theme set gruvbox`: **toda** la app cambia en < 1 s, sin reiniciar — sidebar, cabeceras, chips, glifos de estado, búsqueda, barra de estado, hairlines, terminal (paleta, cursor, selección). Restaurar el tema original al final.
- [ ] Pares de capturas antes/después adjuntos al issue; revisión píxel a píxel de que ningún elemento conserva el color anterior.
- [ ] `grep -rnE '#[0-9a-fA-F]{3,8}\b' src/` solo devuelve `testdata`.
- [ ] Un tema claro (`flexoki-light`) y uno oscuro se ven correctos (jerarquía de texto legible en ambos).
- [ ] Estado idle: sin glifos, sin spinner, sin movimiento — la interfaz se ve vacía y en calma.
- [ ] Resultado anotado en `docs/adr/0001-stack.md` §"Resultado M4".

## Skills
`omarchy-app`.
