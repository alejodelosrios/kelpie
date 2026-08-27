title: Plugin de barra Quickshell `alejodelosrios.kelpie`: bloqueados de un vistazo, invisible en calma, click enfoca
labels: type:feat,area:omarchy
milestone: M5 — Integración Omarchy
---
## Contexto
El toque que vuelve a kelpie app de Omarchy. QML, no Zig: vive en `plugin/` del repo y se instala
en `~/.config/omarchy/plugins/alejodelosrios.kelpie/` (#43). Lee el archivo de estado que kelpie
escribe (#42). Depende de #42.

## Alcance
Entra: `plugin/manifest.json` (`schemaVersion: 1`, `id: "alejodelosrios.kelpie"`, `kinds:
["bar-widget"]`, `entryPoints.barWidget: "BarWidget.qml"`, `barWidget.defaultSection: "right"`,
`allowMultiple: false`); `plugin/BarWidget.qml`: raíz `BarWidget` (`qs.Ui`) con `moduleName`,
`FileView { path: <XDG_STATE_HOME>/kelpie/status.json; watchChanges: true; onFileChanged: reload();
onLoaded: parse(text()) }`, `BarIconButton` con glifo Nerd Font de "bloqueado" + conteo,
`visible: blocked > 0`, tooltip con los títulos, `onPressed`: `bar.run(["kelpie", "focus", <primer
bloqueado>])` (botón izquierdo) o abrir kelpie sin destino (medio); `plugin/README.md` + `LICENSE`.
No entra: panel desplegable, conexión directa al socket de herdr desde QML, configuración.

## Criterios de aceptación
- [ ] `omarchy plugin validate ~/.config/omarchy/plugins/alejodelosrios.kelpie` pasa.
- [ ] Con 0 bloqueados el widget no ocupa espacio en la barra; al bloquearse un agente aparece en < 1 s (sin `omarchy restart shell`).
- [ ] Click enfoca ese agente en kelpie (vía `kelpie focus`), incluso si kelpie estaba cerrado (lo abre y enfoca).
- [ ] Editar `BarWidget.qml` en caliente se refleja al guardar (hot reload documentado).
- [ ] `omarchy restart shell` no rompe el widget (el estado se relee del archivo).
- [ ] Colores solo de `bar.foreground`/`bar.urgent`; nada hardcodeado.

## Referencias
- `/usr/share/omarchy/shell/README.md` ("Installing a third-party plugin", manifest), `shell/services/PluginRegistry.qml`.
- Ejemplos: `shell/plugins/bar/widgets/{Spacer,Microphone,SystemUpdate}.qml`; gotcha `text()` rancio en `Commons/Color.qml:242-252`.
- `~/.config/omarchy/plugins/bibek.focusd/` como plugin de terceros de referencia (layout).

## Skills
`omarchy-app`, `omarchy`.
