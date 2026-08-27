title: Tokens de color: `kelpie.css.tpl` generado por Omarchy, variables de libadwaita y paleta `--term0..15`, cero hex en código
labels: type:feat,area:omarchy,area:ui
milestone: M1 — Consola local (v0.1 usable)
---
## Contexto
Omarchy no tematiza GTK más allá de claro/oscuro; el color real solo llega por una plantilla propia.
En vez de un `kelpie.toml` + conversor a CSS, la plantilla **es** la hoja CSS: el motor de plantillas
de Omarchy la rellena y kelpie solo la carga. Depende de #13.

## Alcance
Entra: `data/themed/kelpie.css.tpl` con `:root { … }` que (a) redefine libadwaita:
`--accent-bg-color: {{ accent }}; --accent-color: {{ accent }}; --window-bg-color: {{ background }};
--window-fg-color: {{ foreground }}; --view-bg-color: {{ dark_background }}; --view-fg-color: {{ foreground }};
--headerbar-bg-color: {{ lighter_background }}; --sidebar-bg-color: {{ background }}; --card-bg-color: {{ lighter_background }};
--popover-bg-color: {{ lighter_background }}; --dialog-bg-color: {{ lighter_background }};
--success-color: {{ green }}; --warning-color: {{ yellow }}; --error-color: {{ red }};`
(b) tokens semánticos de kelpie: `--status-working: {{ blue }}; --status-blocked: {{ yellow }};
--status-done: {{ green }}; --status-danger: {{ red }}; --text-1: {{ bright_foreground }}; --text-2: {{ foreground }};
--text-3: {{ dark_foreground }}; --text-ghost: {{ muted }}; --hairline: alpha({{ foreground }}, .07);
--item-wash: alpha({{ foreground }}, .06); --item-wash-selected: alpha({{ foreground }}, .07);
--accent-wash: alpha({{ accent }}, .13); --status-bar-bg: {{ lighter_background }}; --mode: {{ mode }};
--device-tint-0..4: {{ magenta }} {{ cyan }} {{ purple }} {{ brown }} {{ bright_cyan }};`
(c) paleta del terminal siguiendo `ghostty.conf.tpl`: `--term0: {{ background }} … --term7: {{ foreground }};
--term8: {{ muted }} … --term15: {{ bright_foreground }}; --term-bg: {{ dark_background }}; --term-fg: {{ foreground }};
--term-cursor: {{ bright_foreground }}; --term-selection-bg: {{ selection_background }}; --term-selection-fg: {{ selection_foreground }};`.
En la app: `gtk.CssProvider` cargado desde `$XDG_STATE_HOME/omarchy/current/theme/kelpie.css`
(fallback `~/.local/state/…`), prioridad `APPLICATION`; si no existe, `data/kelpie-fallback.css`
(único lugar con hex permitido: es dato, no código); `src/ui/components.css` (#36) solo usa `var(--…)`.
Instalación de la plantilla: manual en este issue (`cp` a `~/.config/omarchy/themed/` + `omarchy theme set <actual>`); automatizada en #43.
No entra: recarga en vivo (#15), componentes (#36).

## Criterios de aceptación
- [ ] Tras copiar la plantilla y re-aplicar el tema, `~/.local/state/omarchy/current/theme/kelpie.css` existe y no contiene `{{` (ningún token sin sustituir).
- [ ] kelpie arranca y la cabecera, el sidebar y el acento usan los colores del tema activo (captura con `catppuccin` y con `gruvbox`).
- [ ] Sin `kelpie.css` (renombrar temporalmente): kelpie arranca con el fallback y un warning en log; sin crash.
- [ ] `grep -rnE '#[0-9a-fA-F]{3,8}\b' src/` no devuelve nada.
- [ ] Test del parser de `--nombre: valor;` sobre un CSS de ejemplo (usado por #26).

## Referencias
- Skill `omarchy-app` §1 (sintaxis `{{ }}`, funciones, sin alpha en plantilla).
- `/usr/share/omarchy/default/themed/{ghostty.conf,claude.json,hyprland-preview-share-picker.css}.tpl`.
- libadwaita `css-variables.html` (override en `:root`), GTK CSS `alpha()`.

## Skills
`omarchy-app`, `context7`.
