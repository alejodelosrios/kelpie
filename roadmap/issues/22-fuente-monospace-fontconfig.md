title: Fuente del sistema: `monospace` vía Pango/fontconfig, métricas de celda y cambio en vivo
labels: type:feat,area:font
milestone: M2 — Terminal embebido
---
## Contexto
Omarchy fija la fuente de terminal escribiendo `~/.config/fontconfig/fonts.conf` (`omarchy font set`
pone la familia elegida al frente de `monospace`). kelpie pide `monospace` y hereda la elección del
usuario sin hardcodear ninguna tipografía. Depende de #21.

## Alcance
Entra: `PangoFontDescription` con familia `monospace`, tamaño configurable (default 11 pt);
métricas de celda: ancho = avance de `M`, alto = ascent + descent redondeados a píxel entero;
verificación de que los avances de todo ASCII imprimible coinciden (si no, se fuerza el avance);
fallback de glifos (Nerd Font symbols, emoji) delegado a Pango; recarga en vivo cuando cambia
`~/.config/fontconfig/fonts.conf` (GFileMonitor) o llega `kelpie reload-font` (#45): la app
recrea el font map y recalcula la rejilla.
No entra: rasterizado propio, atlas, FreeType/HarfBuzz directos, ligaduras configurables.

## Pregunta abierta (resolver en el PR, anotar la respuesta en la skill)
Cómo forzar que Pango relea fontconfig sin reiniciar. Candidatos: (a) `FcInitBringUptoDate()` vía
translate-c de `<fontconfig/fontconfig.h>` + nuevo `pango_cairo_font_map_new()`; (b)
`pango_font_map_changed()` sobre el mapa por defecto; (c) reiniciar el proceso preservando estado
(último recurso). Elegir el mínimo que pase el criterio de abajo.

## Criterios de aceptación
- [ ] Con `omarchy font current` = JetBrainsMono Nerd Font, el terminal usa esa fuente (comprobar con `pango_font_describe` en un log de debug).
- [ ] `omarchy font set "Ubuntu Mono"` (y luego restaurar) cambia la fuente del terminal en < 2 s sin reiniciar kelpie.
- [ ] Glifos Nerd Font (``, `󰍬`) y un emoji se renderizan (fallback), ocupando 1 y 2 celdas respectivamente.
- [ ] Métricas de celda enteras; una fila de 200 `M` y otra de 200 `i` terminan en el mismo píxel.
- [ ] Test unitario del cálculo de rejilla (ancho_px, alto_px) → (cols, filas) con bordes.

## Referencias
- `/usr/share/omarchy/bin/omarchy-font-set:47-66` (fonts.conf, `prepend_first`, `binding="strong"`).
- context7: Pango `PangoFontMetrics`, `pango_font_map_changed`, `PangoCairoFontMap`; fontconfig `FcInitBringUptoDate`.

## Skills
`zig-libghostty`, `omarchy-app`, `context7`.
