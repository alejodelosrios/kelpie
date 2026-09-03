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
El enjambre OpenCode tiene su copia en `.opencode/skills/`.

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

Pipeline: contexto → scope gate → diseño + Gherkin → Apply → verificación → QA →
auditoría adversaria → docs + PR + CI verde (🛑 **gate humano: el merge**) → cierre.

Los gates de scope y de diseño **los aprueba el PM** — el issue viene enriquecido, así que el diseño
traduce un contrato ya aceptado. **El gate humano es el merge**, más lo que se escala siempre: un
spike que falla su criterio binario, una contradicción issue/código, un auditor que deniega dos
veces.

**Este repo no usa OpenSpec.** El contrato de cada issue es un archivo en `roadmap/designs/<N>-*.md`
con spec, firmas citadas y escenarios Gherkin, aprobado **antes** de escribir código.

| Rol | Motor | Dónde |
|---|---|---|
| Orquestador / PM | Claude (Opus en fleet, Sonnet en hijos) | `.claude/commands/` |
| `core-builder` (`vt,render,pty,rpc,ssh,font`) | Claude Code + `mimo-v2.5-pro` | `.claude/builders/` |
| `ui-builder` (`ui,omarchy,pkg`) | Claude Code + `mimo-v2.5-pro` | `.claude/builders/` |
| `docs-writer` | Claude Code + `mimo-v2.5` (el barato) | `.claude/builders/` |
| `qa` | Claude Sonnet | `.claude/agents/` |
| `auditor` | Claude **Opus** — nunca se abarata | `.claude/agents/` |
| Fallbacks de builder | Claude Sonnet | `.claude/agents/` |

### El enjambre OpenCode (#91) — la alternativa, no el reemplazo

El enjambre **Claude sigue siendo el de referencia**. Junto a él vive una contraparte OpenCode en
`.opencode/`, para el caso de uso **fleet mixto**: un orquestador Claude lanza un pane OpenCode por
issue, y ese OpenCode corre `/kelpie-flow <N>` con sus propios subagentes.

Esto **no contradice #85/#87**, que descalificaron `opencode run` como **arnés headless** por tres
fallos medidos: sin memoria entre invocaciones, stdout bufferizado y builders ciegos a las skills.
Los tres son del arnés, no del runtime: con la herramienta `task` dentro de una sesión viva, la
ronda de corrección reanuda la misma tarea, el reporte llega directo y las skills cargan desde
`.opencode/skills/`. Lo que **sigue prohibido** es recrear un lanzador headless equivalente a
`scripts/kelpie-builder` para OpenCode.

| Rol | Motor | Dónde |
|---|---|---|
| `pm` (`mode: primary`) | `opencode-go/muse-spark-1.3-contributor` | `.opencode/agents/` |
| `core-builder` / `ui-builder` | `mimo/mimo-v2.5-pro` | `.opencode/agents/` |
| `docs-writer` | `mimo/mimo-v2.5` | `.opencode/agents/` |
| `qa` | `opencode-go/deepseek-v4-flash` | `.opencode/agents/` |
| `auditor` | **Claude Opus, en un pane aparte** | `.opencode/agents/` |
| Fallbacks de builder | `opencode-go/glm-5.3` (otra familia a propósito) | `.opencode/agents/` |

**El auditor nunca se abarata, y aquí eso cuesta un pane.** OpenCode no tiene ningún provider de
Anthropic en esta máquina (`opencode models | awk '/anthropic|claude/'` → vacío), así que su agente
`auditor` **no audita**: abre un pane con `herdr agent start --kind claude` y delega en Opus. Con
herdr esa puerta va en las dos direcciones, así que **la elección de motor por rol ya no la limita
qué providers tiene cada CLI**.

Tres reglas que no se deducen leyendo los archivos, y que costaron una prueba cada una:

- El pane se arranca con `herdr agent start <n> --kind opencode --pane <ID> -- --agent pm`. **Sin
  `-- --agent pm` arranca el agente `build`** y no se carga ningún rol del enjambre.
- El prefijo de procedencia del fleet es una **línea literal**:
  `[FLEET] orquestador=<pane> issue=<N> worktree=<ruta> gates=scope,diseño merge=humano`. Un prefijo
  en prosa se rechaza, y el PM hace bien: la procedencia se prueba, no se declara.
- Los agentes van en `.opencode/agents/` (**plural**). `.opencode/agent/` no lo lee OpenCode.

Protocolo de comunicación de los cinco canales, con la evidencia de su primera ejecución:
`.opencode/protocol.md`.

**Verificación sobre confianza:** el PM lee el `git diff` real y **verifica la tabla de citas del
builder ejecutando `sed -n`**. Una cita falsa rechaza el diff aunque compile — ese es el caso
peligroso con un modelo externo: código que compila usando una API que el modelo creyó recordar.

Territorios **disjuntos**: dos builders nunca tocan el mismo archivo. Un issue que cruza territorio se
secuencia (core primero, verificar, commitear, luego ui).

Dos ledgers append-only que solo el PM escribe, con fronteras distintas:
`CONCERNS.md` = deuda del **producto**. `lessons-learned.md` = lo que hizo fallar un **ciclo del
enjambre**, con la regla que lo evita — el PM lo lee en FASE 1 y el auditor cruza el diff contra él.
El conocimiento del **stack** (firmas, rutas) no va a ningún ledger: va a las skills.

## YAGNI

El corte de alcance se hace en el enriquecimiento del issue y en el gate de diseño, donde es gratis.
El mosaico de panes no es el valor de kelpie: eso ya lo hace Hyprland.
