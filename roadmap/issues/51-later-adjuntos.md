title: Enviar adjuntos (archivos e imágenes) al pane de un agente, local y por SSH
labels: type:feat,area:ui,later
milestone:
---
## Contexto
herdrm lo tiene (`AttachmentDelivery.swift`): soltar un archivo sobre el attach lo copia a una
ruta accesible por el agente (local: tal cual; remoto: `scp` a un directorio temporal) y pega la
ruta. No es uno de los 4 valores del proyecto; va después de 1.0.

## Alcance
Entra: drop de archivo/imagen sobre `AttachView`; local → pegar ruta; remoto → `scp -q` a
`~/.cache/kelpie-attachments/` y pegar la ruta remota; captura del portapapeles (imagen) a PNG temporal.
No entra: previsualización, subida a herdr por API.

## Criterios de aceptación
- [ ] Soltar `foto.png` en un agente remoto termina con la ruta remota escrita en su pane y el archivo allí (`ssh host ls`).

## Skills
`zig-libghostty`.
