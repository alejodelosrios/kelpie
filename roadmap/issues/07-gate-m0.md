title: Gate M0 — veredicto de los spikes contra la tabla de aborto del ADR-0001
labels: type:docs
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Cierra M0. Con los resultados de #2, #3, #4, #5 y #6 se decide el camino (o el plan B) antes de
invertir en M1/M2. Depende de #2, #3, #4, #5, #6.

## Alcance
Entra: tabla en `docs/adr/0001-stack.md` (sección "Resultado del gate") con una fila por spike:
pasó/falló, número medido, enlace al issue. Si algún spike falló, se actualiza el ADR con el plan
elegido y se ajustan los issues de M2 afectados (renderer GL en vez de Pango/GSK, etc.).
No entra: empezar features de M1/M2 en este PR.

## Criterios de aceptación
- [ ] Cada spike tiene veredicto binario y evidencia (número o captura) en el ADR.
- [ ] Si todo pasó: los issues de M1 quedan desbloqueados (comentario en cada uno). Si algo falló: se paró, se informó y el ADR describe el fallback adoptado.
- [ ] Las skills `zig-libghostty`/`omarchy-app` incorporan los nombres de API reales aprendidos en los spikes.

## Referencias
- `docs/adr/0001-stack.md` §"Escalera de fallback".

## Skills
—
