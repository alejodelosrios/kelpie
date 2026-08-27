title: Diálogo "Añadir dispositivo" con autocompletado de alias y prueba de conexión
labels: type:feat,area:ui,area:ssh
milestone: M3 — Multi-dispositivo
---
## Contexto
Cierra M3 para el usuario: alta de un remoto con feedback inmediato. Depende de #31, #32, #33, #34.

## Alcance
Entra: `adw.Dialog` con nombre, target (con autocompletado de alias de `~/.ssh/config`), socket
remoto opcional; botón "Probar" que hace sonda de `$HOME` + túnel + `ping` y muestra el resultado
(o el diagnóstico de #32); guardar en #29; editar y eliminar (eliminar tumba el túnel).
No entra: importar dispositivos desde herdrm.

## Criterios de aceptación
- [ ] Alta de un remoto real termina con sus agentes en el sidebar sin reiniciar.
- [ ] "Probar" con herdr parado en el remoto muestra el mensaje de #32 en el propio diálogo.
- [ ] Eliminar un dispositivo cierra su túnel y quita sus agentes en < 1 s.
- [ ] El diálogo usa solo tokens/variables del CSS (cero hex).

## Skills
`omarchy-app`, `context7` (AdwDialog, AdwEntryRow).
