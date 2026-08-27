title: Guardar contraseñas SSH en libsecret (Secret Service)
labels: type:feat,area:ssh,later
milestone:
---
## Contexto
gnome-keyring corre en Omarchy y `Secret-1.gir` está en el sistema, pero zig-gobject no trae el
binding. Fuera del camino crítico: llaves/agente cubren el caso normal (#33).

## Alcance
Entra: opción "Recordar" en el diálogo de contraseña; almacenamiento con la API C de libsecret
(`secret_password_store_sync` / `lookup_sync` vía translate-c de `<libsecret/secret.h>`) bajo un
schema `io.github.alejodelosrios.kelpie`; `kelpie askpass` consulta antes de preguntar; borrar al
eliminar el dispositivo.
No entra: regenerar bindings zig-gobject para Secret-1.

## Criterios de aceptación
- [ ] La contraseña guardada aparece en `seahorse`/`secret-tool search` bajo el schema y se usa sin diálogo en el siguiente arranque.
- [ ] Eliminar el dispositivo elimina el secreto.

## Skills
`zig-libghostty`, `context7` (libsecret).
