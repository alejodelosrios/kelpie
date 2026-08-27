title: Sidebar multi-dispositivo: agregación por máquina y tintes estables por hash (local neutro)
labels: type:feat,area:ui
milestone: M3 — Multi-dispositivo
---
## Contexto
Con varios dispositivos el sidebar necesita decir "de qué máquina es" sin gritar: herdrm usa 5
tintes que no chocan con los colores de estado, asignados por hash del id, y deja el local neutro.
Replicamos la regla con tokens del tema. Depende de #16, #29.

## Alcance
Entra: cabecera de dispositivo (nombre, badge OS, estado del túnel) por grupo; orden: local primero,
luego por nombre; tinte del chip = `--device-tint-{hash(id) % 5}` definidos en `kelpie.css.tpl`
como `magenta cyan purple brown bright_cyan` (ninguno es color de estado); local = `foreground`;
el orden por urgencia (#12) es global, cruzando dispositivos, en la vista "Todos".
No entra: reordenar dispositivos a mano.

## Criterios de aceptación
- [ ] Dos dispositivos remotos reciben tintes distintos y estables entre reinicios (test del hash).
- [ ] El dispositivo local no lleva tinte.
- [ ] Ningún tinte coincide con `--status-working/blocked/done/danger` del tema activo (test comparando los tokens del CSS generado).
- [ ] Un tema sin `purple`/`brown` explícitos sigue funcionando (Omarchy los sintetiza).

## Referencias
- Regla y alfas medidos en `Theme.swift:49-62` del fork de herdrm (solo la regla; no copiar código).
- Skill `omarchy-app` §mapeo de tokens.

## Skills
`omarchy-app`.
