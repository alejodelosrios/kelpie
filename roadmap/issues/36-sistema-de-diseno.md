title: Sistema de diseño: hoja CSS de componentes con las métricas reales de herdrm
labels: type:feat,area:ui
milestone: M4 — Acabado visual
---
## Contexto
La estructura, tipografía, espaciado y jerarquía se copian de herdrm; los colores salen de los
tokens de Omarchy (#14). Aquí se fija la hoja de componentes que todas las vistas usan. Métricas
medidas en el fork de herdrm (`Sources/HerdrM/*.swift`). Depende de #16, #27.

## Alcance
Entra: `src/ui/components.css` (estructura, sin colores literales: solo `var(--…)`/`alpha()`):
- Espaciado: unidad 8; usados 4, 5, 6, 8, 9, 10, 12, 14, 16, 20. Padding horizontal típico 8/10/16, vertical 7/8/12.
- Filas de lista 28 y 30 px; cabeceras 42 px; separadores **hairline de 1 px** con `alpha(var(--fg), .06)` (18 usos en herdrm: la UI se estructura con hairlines, no con cajas).
- Tipografía: 11.5 regular es el cuerpo más frecuente; 13 medium filas principales; 12.5 medium; 12 semibold; 11 bold etiquetas; 10.5 bold (check); 9 semibold micro-etiquetas; **28 light** estado vacío.
- Radios: 6 y 7 (chips/filas), 9 y 10 (paneles), 4-5 (badges).
- Materiales: lavados `alpha(var(--fg), .06/.07)` en lugar de rellenos; **una sola sombra** en toda la app (popover de búsqueda); la translucidez de ventana la da el tag `default-opacity` de Omarchy, no la app.
- Barra de estado inferior sobre `--status-bar-bg` (lighter_background).
No entra: animaciones (#39), búsqueda (#37).

## Criterios de aceptación
- [ ] `grep -rnE '#[0-9a-fA-F]{3,8}\b' src/ui/ src/*.zig` no devuelve nada (cero hex fuera de testdata).
- [ ] Captura lado a lado con herdrm (mismo tema oscuro): alturas de fila, hairlines y tamaños coinciden a ±1 px.
- [ ] Exactamente una regla `box-shadow` en toda la CSS.
- [ ] El estado vacío ("sin agentes") muestra el texto a 28 px light centrado y nada más.
- [ ] libadwaita 1.9: la hoja se carga con prioridad `APPLICATION` y no rompe `adw` (inspector GTK sin warnings de CSS).

## Referencias
- Skill `omarchy-app` §mapeo semántico. Métricas: `ContentView.swift`, `SidebarView.swift`, `Theme.swift` del fork (solo medidas).
- context7: libadwaita `style-classes.html`, `css-variables.html`.

## Skills
`omarchy-app`, `context7`.
