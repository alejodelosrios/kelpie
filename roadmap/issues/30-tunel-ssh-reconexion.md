title: Túnel `ssh -N -L sock:sock` como subproceso con reconexión 1 s → 30 s por dispositivo
labels: type:feat,area:ssh,risk:high
milestone: M3 — Multi-dispositivo
---
## Contexto
herdr solo escucha en un socket Unix local; a un herdr remoto se llega reenviando ese socket con
OpenSSH (stream-local forward). El túnel es un proceso `ssh` por dispositivo, vigilado y
reconectado. Depende de #29, #10.

## Alcance
Entra: `Tunnel.zig` que (1) resuelve `$HOME` remoto (`ssh <target> 'printf %s "$HOME"'`) y forma
`<home>/.config/herdr/herdr.sock` salvo `socket_path` explícito; (2) lanza
`ssh -N -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ExitOnForwardFailure=yes
-o ServerAliveInterval=15 -o StreamLocalBindUnlink=yes -L <local>:<remoto> <target>` con
`<local>` = `$XDG_RUNTIME_DIR/kelpie/<device-id>.sock`; (3) espera a que exista el socket local y
lo entrega al cliente RPC (#8) y al stream de eventos (#10); (4) al morir `ssh`, reintenta con
backoff 1, 2, 4, …, 30 s (tope) y resetea al reconectar; (5) teardown: SIGTERM al hijo, unlink del
socket, sin procesos huérfanos al salir de kelpie.
No entra: autenticación interactiva (#33), diagnóstico de forward silencioso (#32), scp.

## Criterios de aceptación
- [ ] Con un host con herdr corriendo: el sidebar muestra sus agentes vía `agent.list` a través del socket local.
- [ ] Matar el `ssh` a mano → reconecta solo; el log muestra la secuencia de esperas 1,2,4,8,16,30,30.
- [ ] Desconectar la red 20 s y volver → los eventos vuelven a fluir sin reiniciar kelpie.
- [ ] Al salir de kelpie no queda ningún `ssh -N` hijo (`pgrep -f kelpie/.*\.sock` vacío) ni socket en `$XDG_RUNTIME_DIR/kelpie/`.
- [ ] Dos dispositivos remotos a la vez no comparten socket ni proceso.
- [ ] Test unitario del backoff (secuencia y tope) sin lanzar ssh.

## Referencias
- `man ssh` (`-L` con rutas Unix, `StreamLocalBindUnlink`, `ExitOnForwardFailure`); `man sshd_config` (`AllowStreamLocalForwarding`).
- Referencia de comportamiento (no copiar): `Packages/HerdrKit/Sources/HerdrKit/SSHTunnel.swift:108-141` del fork de herdrm.

## Skills
`zig-libghostty`.
