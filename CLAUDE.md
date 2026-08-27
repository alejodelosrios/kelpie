# kelpie — reglas del repo y del enjambre

Consola nativa de Omarchy para [herdr](https://github.com/herdrdev/herdr). **Zig 0.16** + módulo Zig
`ghostty-vt` + **GTK4/libadwaita**. Decisiones en `docs/adr/`; roadmap en GitHub issues.

## La regla que manda sobre todas

**Ninguna firma de API se escribe de memoria.** Zig 0.16 estrenó firmas, la API de `ghostty-vt` es
explícitamente inestable y va pinneada por commit, y los bindings de GTK4 son generados. Lo que
"recuerdas" está desactualizado o nunca existió.

Fuentes de verdad, en orden:
1. Mirror pinneado `~/.cache/ghostty-build/src/ghostty/` (commit `15ff186f65ca0bdbd1fa397ab03908d59de16463`):
   `example/zig-vt/`, `src/lib_vt.zig`, `include/ghostty/vt/render.h`, `src/apprt/gtk/`.
2. El toolchain instalado (`zig build --help`, `zig init`).
3. `context7` para GTK4/libadwaita/Pango.
4. La máquina, para todo lo de Omarchy (`/usr/share/omarchy/bin/`). Cuando la doc y la máquina no
   cuadren, **gana la máquina**.

Si no encuentras la API, **no la inventes**: va como pregunta abierta al issue. Un hueco declarado es
seguro; una suposición con forma de dato, no.

Skills del repo en `.claude/skills/`: `zig-libghostty` (APIs verificadas, contrato de filas sucias) y
`omarchy-app` (rutas, temas, notificaciones, barra, empaquetado). Cárgalas según el `area:*` del issue.

## Reglas duras de código

- `build.zig.zon` y el commit pinneado de ghostty son intocables fuera de un issue dedicado.
  **Cero dependencias nuevas.**
- **No reimplementes nada de `ghostty-vt`** (ADR-0001 §2).
- **Cero hexadecimales de color en el código** (ADR-0001 §5): el color llega del CSS generado por
  plantilla de tema.
- **Sin `unreachable`/`catch unreachable`** en caminos de render o de error. Un panic mata la sesión.
- `Terminal`/`RenderState` bajo mutex; nunca pintar desde el hilo lector del PTY; nunca bloquear el
  hilo de UI.
- `/usr/share/omarchy/` se lee y jamás se escribe. El paquete no escribe en `$HOME`: eso es
  `kelpie setup`.
- Commits convencionales que explican el **por qué**. Cada decisión irreversible, un ADR numerado.

## Modelo de ramas

```
develop  ← rama base de integración. TODO sale de aquí y vuelve aquí por PR.
  feature/<N>-<slug>   fix/<N>-<slug>   docs/<N>-<slug>   chore/<N>-<slug>
main     ← solo recibe de develop en release, a mano, fuera del enjambre.
```

Un ruleset de GitHub protege `develop` y `main`: PR obligatorio, check `build` en verde, rama al día
(rebase), sin force-push ni borrado. **Nada se mergea en rojo** — y no depende de que alguien se
acuerde.

## El enjambre

Dos puertas: **`/kelpie-flow <N>`** para un issue, **`/kelpie-fleet <N> <M> …`** para varios (el flow
te redirige si le pasas más de uno). Helpers: `/kelpie-issue` y `/kelpie-research`.

Pipeline: contexto → scope gate → **diseño + Gherkin (🛑 gate humano)** → Apply → verificación → QA →
auditoría adversaria → docs + PR + CI verde (🛑 gate humano) → cierre.

**Este repo no usa OpenSpec.** El contrato de cada issue es un archivo en `roadmap/designs/<N>-*.md`
con spec, firmas citadas y escenarios Gherkin, aprobado **antes** de escribir código.

| Rol | Motor | Dónde |
|---|---|---|
| Orquestador / PM | Claude (Opus en fleet, Sonnet en hijos) | `.claude/commands/` |
| `core-builder` (`vt,render,pty,rpc,ssh,font`) | OpenCode + `mimo-v2.5-pro` | `.opencode/agents/` |
| `ui-builder` (`ui,omarchy,pkg`) | OpenCode + `mimo-v2.5-pro` | `.opencode/agents/` |
| `docs-writer` | OpenCode + `mimo-v2.5-pro` | `.opencode/agents/` |
| `qa` | Claude Sonnet | `.claude/agents/` |
| `auditor` | Claude **Opus** — nunca se abarata | `.claude/agents/` |
| Fallbacks de builder | Claude Sonnet | `.claude/agents/` |

**Verificación sobre confianza:** el PM lee el `git diff` real y **verifica la tabla de citas del
builder ejecutando `sed -n`**. Una cita falsa rechaza el diff aunque compile — ese es el caso
peligroso con un modelo externo: código que compila usando una API que el modelo creyó recordar.

Territorios **disjuntos**: dos builders nunca tocan el mismo archivo. Un issue que cruza territorio se
secuencia (core primero, verificar, commitear, luego ui).

Preocupaciones que no bloquean → `CONCERNS.md` (append-only, solo el PM escribe).

## YAGNI

El corte de alcance se hace en el enriquecimiento del issue y en el gate de diseño, donde es gratis.
El mosaico de panes no es el valor de kelpie: eso ya lo hace Hyprland.
