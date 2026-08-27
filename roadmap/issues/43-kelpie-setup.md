title: `kelpie setup`: instala plantilla de tema, plugin de barra y hooks en el `$HOME` del usuario, idempotente
labels: type:feat,area:omarchy,area:pkg
milestone: M5 — Integración Omarchy
---
## Contexto
El paquete no puede escribir en `$HOME` y Omarchy solo lee plantillas de `~/.config/omarchy/themed/`
y plugins de `~/.config/omarchy/plugins/`. Un comando hace la parte de usuario, se puede repetir y
se puede deshacer. Depende de #14, #41, #45.

## Alcance
Entra: `kelpie setup [--dry-run] [--no-plugin] [--hooks] [--uninstall]` que, leyendo los assets
instalados por el paquete en `/usr/share/kelpie/`: (1) copia `themed/kelpie.css.tpl` a
`~/.config/omarchy/themed/` si no existe o si el existente es idéntico a una versión anterior
nuestra (hash conocido; una plantilla editada por el usuario no se pisa: se avisa); (2) regenera el
tema con `omarchy theme set "$(< ~/.local/state/omarchy/current/theme.name)"` — verificar que acepta
el nombre tal cual está en `theme.name`; (3) copia `plugin/` a `~/.config/omarchy/plugins/alejodelosrios.kelpie/`
y, si no está en `shell.json`, `omarchy plugin enable alejodelosrios.kelpie --section right`;
(4) con `--hooks`, `omarchy hook install theme-set /usr/share/kelpie/hooks/kelpie-theme-set` y
`font-set`; (5) imprime cada acción; `--uninstall` revierte lo que instaló (nunca `shell.json` a mano).
No entra: escribir en `/usr/share/omarchy/`, tocar `hooks/theme-set` (archivo suelto), editar `shell.json` a mano.

## Criterios de aceptación
- [ ] Ejecutar `kelpie setup` dos veces seguidas: la segunda no cambia nada ("ya instalado" en cada paso).
- [ ] Tras `setup`, existe `~/.local/state/omarchy/current/theme/kelpie.css` y kelpie arranca tematizado.
- [ ] Una `kelpie.css.tpl` modificada por el usuario se conserva y se avisa; `--force` la reemplaza haciendo backup `.bak`.
- [ ] `--uninstall` quita plantilla, plugin (vía `omarchy plugin remove`/`disable`), hooks; la barra vuelve a su estado.
- [ ] `--dry-run` no escribe nada (`inotifywait` sobre `~/.config/omarchy/` en silencio).
- [ ] Test del decisor "copiar / conservar / avisar" con hashes.

## Referencias
- Skill `omarchy-app` §1, §3; `/usr/share/omarchy/bin/omarchy-hook-install:18-29`; `omarchy plugin --help`.

## Skills
`omarchy-app`, `omarchy`.
