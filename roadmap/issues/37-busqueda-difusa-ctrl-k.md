title: Búsqueda global difusa (`Ctrl+K`) de agentes en todos los dispositivos, con los mismos glifos de estado
labels: type:feat,area:ui
milestone: M4 — Acabado visual
---
## Contexto
Valor #3 del proyecto. Un atajo, una caja, resultados ordenados por relevancia y urgencia, Enter
enfoca por el mismo camino que `kelpie focus`. Depende de #17, #34.

## Alcance
Entra: `Fuzzy.zig` (coincidencia por subsecuencia con bonus por inicio de palabra y adyacencia,
≤ 80 líneas, test de tabla); popover/diálogo sobre la ventana con campo de texto y lista; filas de
28 px con `AgentStatusGlyph` (mismo widget del sidebar), título, espacio y chip de dispositivo con
su tinte; navegación con flechas, Enter enfoca, Esc cierra; ordena por puntuación y, a igual
puntuación, por urgencia (#12).
No entra: buscar en el contenido de los panes, historial de búsquedas.

## Criterios de aceptación
- [ ] `Ctrl+K` abre en < 100 ms con 200 agentes en 3 dispositivos; teclear filtra sin lag perceptible.
- [ ] `clau bac` encuentra "claude · backend-api" por delante de "claude · frontend" (test).
- [ ] Enter en un agente remoto lo enfoca (attach) igual que el click en el sidebar.
- [ ] El glifo de estado en los resultados es idéntico al del sidebar (mismo widget, misma regla de idle invisible).
- [ ] Esc cierra y devuelve el foco donde estaba.

## Referencias
- `SearchView.swift` del fork (comportamiento, sin copiar). Skill `omarchy-app`.

## Skills
`omarchy-app`, `context7` (GtkShortcutController, AdwDialog).
