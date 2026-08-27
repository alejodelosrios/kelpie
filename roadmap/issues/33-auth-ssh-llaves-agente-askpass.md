title: Autenticación SSH: llaves/agente primero; contraseña vía `SSH_ASKPASS` gráfico sin persistir
labels: type:feat,area:ssh
milestone: M3 — Multi-dispositivo
---
## Contexto
Omarchy no arranca ssh-agent y `SSH_AUTH_SOCK` puede estar vacío; gnome-keyring sí corre. kelpie
prueba primero sin interacción y, si hace falta contraseña, la pide con un diálogo. Guardarla en
libsecret queda para después (#50). Depende de #30.

## Alcance
Entra: primer intento con `-o BatchMode=yes` (llaves, agente si `SSH_AUTH_SOCK` existe, Tailscale
SSH); si falla por autenticación, segundo intento con `-o BatchMode=no -o NumberOfPasswordPrompts=1`,
`SSH_ASKPASS=kelpie`, `SSH_ASKPASS_REQUIRE=force` y el subcomando `kelpie askpass "<prompt>"` que
abre un `adw.AlertDialog` con campo de contraseña y la imprime por stdout; `accept-new` para hosts
nuevos con aviso visible.
No entra: guardar contraseñas (#50), passphrases de llaves (las gestiona el agente del usuario).

## Criterios de aceptación
- [ ] Un host con llave autorizada conecta sin ningún diálogo.
- [ ] Un host solo-contraseña muestra el diálogo una vez; contraseña incorrecta → error claro y reintento manual, no bucle.
- [ ] La contraseña no queda en logs, ni en argv (`ps` no la muestra), ni en disco.
- [ ] `SSH_AUTH_SOCK` vacío no rompe el primer intento.
- [ ] Test: el parser de la salida de error de ssh clasifica "Permission denied (publickey,password)" como `needs_password`.

## Referencias
- `man ssh` (`SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE`), `man ssh_config` (`BatchMode`, `NumberOfPasswordPrompts`).
- Referencia de comportamiento (no copiar): `SSHTunnel.swift:486-492` del fork de herdrm.

## Skills
`zig-libghostty`, `context7` (AdwAlertDialog).
