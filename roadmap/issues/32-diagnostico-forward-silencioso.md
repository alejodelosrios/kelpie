title: Diagnóstico de forward silencioso: distinguir "herdr no corre allí" de "sshd no permite forwards"
labels: type:feat,area:ssh
milestone: M3 — Multi-dispositivo
---
## Contexto
Cuando el socket remoto no existe, `ssh -L` acepta la conexión local y la deja morir en silencio:
kelpie ve timeouts, no errores. herdrm aprendió esto a golpes; kelpie lo sondea a la primera.
Depende de #30.

## Alcance
Entra: cuando el túnel está arriba pero el primer `ping` (#8) da EOF/timeout, ejecutar
`ssh <target> 'test -S "<remoto>" && echo exists || echo missing'` y mapear: `missing` → "herdr
no está corriendo en <host>. Ejecuta `herdr` allí"; `exists` → "sshd en <host> no permite
forwards de socket (`AllowStreamLocalForwarding`)"; otra salida → mostrar stderr recortado. El
mensaje va al estado del dispositivo en el sidebar y al diálogo (#35).
No entra: arrancar herdr remoto automáticamente.

## Criterios de aceptación
- [ ] Con herdr parado en el remoto, el sidebar muestra el mensaje "no está corriendo" en < 15 s.
- [ ] Con herdr corriendo pero `AllowStreamLocalForwarding no`, el mensaje es el de sshd.
- [ ] Test de tabla del mapeo `probeOutput → mensaje` (exists / missing / vacío / basura).

## Referencias
- Referencia de comportamiento (no copiar): `SSHTunnel.swift:222-265` del fork de herdrm.
- `man sshd_config` → `AllowStreamLocalForwarding`.

## Skills
`zig-libghostty`.
