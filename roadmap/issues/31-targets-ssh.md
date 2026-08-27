title: Targets SSH: `user@host`, `user@host:port` → `ssh://`, URIs `ssh://` y alias de `~/.ssh/config`
labels: type:feat,area:ssh
milestone: M3 — Multi-dispositivo
---
## Contexto
La gente escribe el destino de tres formas; OpenSSH entiende `ssh://user@host:port` y los alias.
kelpie normaliza y delega. Depende de #30.

## Alcance
Entra: `Target.normalize(input) -> []const u8`: `ssh://…` pasa tal cual; `user@host:2222` →
`ssh://user@host:2222`; `user@host` y `host` pasan tal cual (OpenSSH resuelve alias); IPv6 sin
corchetes se envuelve `[…]` solo si trae puerto; lectura de `~/.ssh/config` (`Host` sin comodines)
para autocompletar en #35.
No entra: parsear `Include`/`Match` de ssh_config, ProxyJump propio.

## Criterios de aceptación
- [ ] Tests de tabla: `vincent@10.0.0.7`, `vincent@studio.tail:2222`, `ssh://a@b:1`, `mac-studio` (alias), `fe80::1` y `[fe80::1]:22` producen lo esperado.
- [ ] Un alias de `~/.ssh/config` con `HostName`, `User` y `Port` distintos conecta sin que kelpie los lea.
- [ ] La lista de alias aparece en el autocompletado del diálogo (#35), sin comodines (`Host *`).

## Referencias
- `man ssh` (formato `ssh://`), `man ssh_config`.

## Skills
`zig-libghostty`.
