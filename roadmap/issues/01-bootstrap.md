title: Bootstrap del repo: build.zig 0.16, CI en Arch, MIT, ADR-0001 y skills del proyecto
labels: type:chore,area:pkg
milestone: M0 — Gate: spikes y bootstrap
---
## Contexto
Primer issue de M0. Deja el esqueleto sobre el que corren los spikes: sin esto no hay `zig build`
que probar. Hecho en el commit inicial; este issue documenta qué se considera bootstrap.

## Alcance
Entra: `build.zig` + `build.zig.zon` generados con la plantilla de `zig init` 0.16, `src/main.zig`
que imprime nombre y versión, `zig build test` con un test real, CI en contenedor `archlinux`
(`zig fmt --check`, `zig build`, `zig build test`), LICENSE MIT, README, `docs/adr/0001-stack.md`,
`.claude/skills/zig-libghostty/SKILL.md`, `.claude/skills/omarchy-app/SKILL.md`,
`.github/ISSUE_TEMPLATE/bug.md`, `scripts/gh-roadmap.sh`.
No entra: ninguna dependencia (ghostty, gobject) — eso es Spike A y B.

## Criterios de aceptación
- [ ] `zig build && ./zig-out/bin/kelpie` imprime `kelpie 0.0.0`.
- [ ] `zig build test` pasa; `zig fmt --check build.zig build.zig.zon src` no reporta nada.
- [ ] El workflow `ci` pasa en verde en GitHub Actions sobre `archlinux:latest`.
- [ ] Las dos skills existen y el ADR-0001 contiene la tabla de aborto de los spikes.

## Referencias
- `zig init` (0.16) es la plantilla autorizada: `pub fn main(init: std.process.Init)`.
- `docs/adr/0001-stack.md`.

## Skills
`zig-libghostty`.
