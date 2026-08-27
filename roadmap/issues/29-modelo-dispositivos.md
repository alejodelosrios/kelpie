title: Modelo de dispositivos: local + SSH, persistencia JSON y badge de sistema operativo
labels: type:feat,area:ssh
milestone: M3 — Multi-dispositivo
---
## Contexto
Primer paso de M3: representar "una máquina con herdr". El dispositivo local existe siempre y va
primero; los remotos se persisten. Depende de #20 (gate M1).

## Alcance
Entra: `Device { id (uuid), name, kind: local | ssh(target), socket_path: ?[]u8, os_id: ?[]u8 }`,
`DeviceStore` en `$XDG_CONFIG_HOME/kelpie/devices.json` (escritura atómica tmp+rename, lectura
tolerante: entradas inválidas se descartan con log), local siempre presente y primero; sonda de OS
por SSH (`. /etc/os-release && echo $ID`, cacheado en `os_id`) para el badge del sidebar.
No entra: UI de alta (#35), túneles (#30).

## Criterios de aceptación
- [ ] `devices.json` inexistente → lista `[local]`; JSON corrupto → `[local]` + warning, sin crash.
- [ ] Guardar y recargar preserva id, nombre, target, socket_path y os_id.
- [ ] Un dispositivo remoto nunca desplaza al local del índice 0.
- [ ] Tests: round-trip JSON, corrupto, y un `local` duplicado en el archivo se colapsa a uno.

## Referencias
- Comportamiento de referencia (no copiar código): `Packages/HerdrKit/Sources/HerdrKit/Device.swift` del fork de herdrm.
- Zig: `std.json`, `std.fs.rename` para escritura atómica.

## Skills
`zig-libghostty`.
