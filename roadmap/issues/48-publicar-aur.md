title: Publicar en AUR y probar `omarchy pkg aur add kelpie` en una máquina Omarchy limpia
labels: type:chore,area:pkg
milestone: M6 — Distribución
---
## Contexto
El gate de M6: instalación de extremo a extremo con los comandos de Omarchy. Depende de #47, #43.

## Alcance
Entra: repo AUR `kelpie` con `PKGBUILD` + `.SRCINFO` desde `packaging/`, versión etiquetada en
GitHub (`v0.1.0`) con `sha256sums`; prueba en una instalación limpia de Omarchy (VM o máquina):
`omarchy pkg aur add kelpie && kelpie setup` y checklist; script `scripts/release.sh` que etiqueta,
actualiza `pkgver`/sums y hace push al AUR.
No entra: repositorio binario propio.

## Criterios de aceptación
- [ ] En Omarchy limpia: `omarchy pkg aur add kelpie` instala; `kelpie setup` deja tema, plugin y `.desktop` funcionando; primer agente bloqueado produce toast clickeable. Tiempo total < 2 min tras compilar.
- [ ] `yay -Si kelpie` / `paru -Si kelpie` muestran la versión etiquetada.
- [ ] `scripts/release.sh` es idempotente para la misma versión.

## Skills
`omarchy-app`, `omarchy`.
