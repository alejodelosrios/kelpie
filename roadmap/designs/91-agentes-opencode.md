# Diseño — #91 Agentes OpenCode del enjambre

> Aprobado por: Manuel Alejandro Ramirez (humano) · 2026-09-03

## Spec

La contraparte OpenCode del enjambre, para que un **fleet mixto** (orquestador Claude → PMs OpenCode)
pueda correr flujos completos. El contenido de los roles se calca de `.claude/`; lo que cambia es el
**arnés** (herramienta `task` in-proceso en vez de `scripts/kelpie-builder`) y el **motor del
auditor**, que sale del proceso.

**Archivos que se crean** (territorio `docs-writer` — no se toca una línea de Zig):

| Archivo | Basado en |
|---|---|
| `.opencode/agents/core-builder.md` | `.claude/builders/core-builder.md` |
| `.opencode/agents/ui-builder.md` | `.claude/builders/ui-builder.md` |
| `.opencode/agents/docs-writer.md` | `.claude/builders/docs-writer.md` |
| `.opencode/agents/qa.md` | `.claude/agents/qa.md` |
| `.opencode/agents/auditor.md` | `.claude/agents/auditor.md` — **delegador**, ver §Auditor |
| `.opencode/agents/core-builder-fallback.md` | `.claude/agents/core-builder-fallback.md` |
| `.opencode/agents/ui-builder-fallback.md` | `.claude/agents/ui-builder-fallback.md` |
| `.opencode/agents/pm.md` | rol PM extraído de `.claude/commands/kelpie-flow.md` |
| `.opencode/commands/kelpie-flow.md` | `.claude/commands/kelpie-flow.md`, adaptado |
| `.opencode/protocol.md` | nuevo, canónico |
| `.opencode/opencode.json` | nuevo |
| `.opencode/skills/zig-libghostty/`, `.opencode/skills/omarchy-app/` | copia de `.claude/skills/` |

**No entra**: `.opencode/commands/kelpie-fleet.md`, lanzador headless equivalente a
`scripts/kelpie-builder` (es lo que #85 descalificó), migración del fleet Claude, `.claude/`,
`build.zig.zon`.

## Hallazgos de máquina que fijan el diseño

Los cinco se verificaron ejecutando, no leyendo documentación.

### 1. El directorio es `agents/` (plural), y el singular NO carga

Verificado por partida doble. `opencode agent create --path .opencode` —el propio generador de
OpenCode— escribió en `.opencode/agents/sonda-ruta-canonica.md`. Y con dos sondas escritas a mano,
una en cada directorio, `opencode agent list` listó **solo** la de `agents/`:

```
$ opencode agent list | awk '/sonda/'
sonda-plural (subagent)          # .opencode/agents/  → carga
                                 # .opencode/agent/   → NO aparece
```

Es la clase de detalle que habría costado un ciclo entero: los archivos existen, el `git diff` se ve
perfecto, y ningún agente carga.

### 2. No hay provider de Anthropic en OpenCode en esta máquina

`opencode models | awk '/anthropic|claude/'` → vacío. Los 40 modelos disponibles son de
`opencode/`, `opencode-go/`, `mimo/` y `ollama/`. **Consecuencia directa: la invariante «el auditor
nunca se abarata» no se puede cumplir con un subagente OpenCode.**

### 3. `subagent_depth` por defecto es 1, y eso fija `mode` del PM

Schema (`opencode.ai/config.json`, `$defs.Config.properties.subagent_depth`): *"Maximum subagent
nesting depth. Defaults to 1, which prevents subagents from launching subagents."*

Por tanto `pm.md` va **`mode: primary`**, no por gusto de UX sino porque un PM en `subagent` no
podría lanzar a sus builders. Resuelve la pregunta abierta 2 del expediente con evidencia.

### 4. `herdr agent start` acepta `--kind claude`

```
Usage: herdr agent start <NAME> --kind <KIND> --pane <ID>
[possible values: pi, claude, codex, gemini, cursor, ..., opencode, ...]
```

Es el mecanismo que hace posible el §Auditor. El pane debe estar en su prompt de shell.

### 5. Frontmatter válido (schema `$defs.AgentConfig`)

`mode` ∈ `{subagent, primary, all}` · `model`, `variant`, `temperature`, `prompt`, `tools`,
`description`, `permission`, `steps`/`maxSteps`.
`permission` acepta las claves `read, edit, glob, grep, list, bash, task, external_directory,
todowrite, question, webfetch, websearch, lsp, doom_loop`, con valores `ask|allow|deny`.

## El auditor no se abarata: sale del proceso

Decisión del dueño, y el hallazgo 2 la hace obligatoria. El `auditor.md` de OpenCode **no audita**:
es un **delegador** que abre un pane con Claude Code y le pasa el trabajo.

```
PM OpenCode
  → task → .opencode/agents/auditor.md   (delegador, modelo barato: solo orquesta)
      → herdr pane split + herdr agent start auditor-<N> --kind claude --pane <ID>
      → herdr agent prompt  (diff congelado + diseño + lessons-learned.md)
      → herdr agent read    (veredicto binario)
  ← veredicto APROBADO/DENEGADO por el mensaje final del task
```

El auditor real sigue siendo **Claude Opus**, con el cuerpo de rol de `.claude/agents/auditor.md`
sin tocar. Lo que cambia es quién lo invoca. Coste: un pane y una espera; a cambio, la invariante se
mantiene literalmente en vez de degradarse a "el más capaz que había".

**Corolario que el diseño hace explícito**: el mismo mecanismo sirve al revés. Con herdr, un pane
Claude y un pane OpenCode se abren y se hablan en ambas direcciones, así que la elección de motor por
rol deja de estar limitada por qué providers tiene cada CLI. `protocol.md` lo documenta como canal 5.

## Los cinco canales, cada uno con su verificación ejecutable

Requisito del dueño: *«todos los flujos tienen comunicación funcional»*. Así que cada canal lleva su
comando de prueba y su evidencia pegada — no basta con documentarlo.

| # | Quién | Mecanismo | Verificación ejecutable |
|---|---|---|---|
| 1 | Orquestador Claude → PM OpenCode | `herdr agent prompt` | el PM responde presentando FASE 1 con el prefijo de procedencia reconocido |
| 2 | PM OpenCode → orquestador | `agent_status` + transcript | `herdr pane list` muestra `idle` en el gate; `herdr agent read` devuelve el texto del gate |
| 3 | PM → builders/qa | herramienta `task` | cada agente responde identificándose con su rol y su modelo (el PONG) |
| 4 | Builder → PM | mensaje final del `task` | el reporte trae la tabla de citas completa |
| 5 | **PM OpenCode ↔ auditor Claude** | `herdr agent start --kind claude` + `prompt`/`read` | el pane arranca, recibe el diff y devuelve veredicto binario |

**Regla de oro, literal en `protocol.md`:** *nada se transmite solo de voz.* Todo gate, reporte o
pregunta queda escrito donde persiste. Un pane se puede cerrar; lo que no está escrito se pierde.

Descubribilidad: los 8 agentes + el comando llevan tras el frontmatter la misma línea grepeable
apuntando a `.opencode/protocol.md` y nombrando su canal.

## Modelos por rol

Con el hallazgo 2, la tabla **aprobada por el dueño** en el gate de diseño:

| Rol | Motor | Por qué |
|---|---|---|
| `pm` | `opencode-go/muse-spark-1.3-contributor` | **decisión del dueño**; orquesta y verifica con `sed`, no escribe producción |
| `core-builder` / `ui-builder` | `mimo/mimo-v2.5-pro` | mismo motor que el enjambre Claude, contexto 1M |
| `docs-writer` | `mimo/mimo-v2.5` | prosa, no firmas |
| `qa` | `opencode-go/deepseek-v4-flash` | **decisión del dueño**; escribe y ejecuta tests |
| `auditor` | **Claude Opus vía pane** | la invariante, sin abaratar |
| fallbacks | `opencode-go/glm-5.3` | motor distinto al del builder que reemplazan |

Los fallbacks cambian de familia a propósito: un fallback con el mismo motor que acaba de fallar
repite el fallo.

## Escenarios (Gherkin)

```gherkin
Escenario: los agentes cargan desde el directorio correcto
  Dado .opencode/agents/ con los 8 archivos
  Cuando se ejecuta `opencode agent list`
  Entonces los 8 aparecen listados con su mode
  Y ninguno vive en .opencode/agent/ (singular), que OpenCode no lee

Escenario: el auditor no se abarata
  Dado que `opencode models` no ofrece ningún provider de Anthropic
  Cuando el PM lanza el task del auditor
  Entonces el auditor abre un pane con `herdr agent start --kind claude`
  Y el veredicto lo emite Claude Opus con el cuerpo de .claude/agents/auditor.md
  Y el mensaje final del task devuelve APROBADO o DENEGADO al PM

Escenario: el protocolo es descubrible desde cualquier rol
  Dado los 8 agentes y el comando kelpie-flow
  Cuando se ejecuta `grep -l "protocol.md" .opencode/agents/*.md .opencode/commands/*.md`
  Entonces lista los 9 archivos

Escenario: el PM reconoce la procedencia del fleet y no se detiene en el scope gate
  Dado un pane OpenCode arrancado por el orquestador
  Cuando recibe "/kelpie-flow N" con el prefijo de procedencia
  Entonces reporta el scope al orquestador y sigue, sin detenerse
  Y con "/kelpie-flow N" a secas SÍ se detiene y pide aprobación humana

Escenario: los cinco canales están vivos, no solo documentados
  Dado el enjambre OpenCode instalado
  Cuando se corre el smoke test de cada canal de la tabla §Los cinco canales
  Entonces cada uno produce su evidencia y queda pegada en el PR
  Y un canal sin evidencia ejecutada cuenta como criterio NO cumplido

Escenario: cero credenciales versionadas
  Cuando se ejecuta `git grep -i "mimo.key\|tp-s67"` sobre .opencode/
  Entonces no devuelve nada

Escenario: el repo sigue compilando
  Cuando se ejecuta `zig build` y `zig build test`
  Entonces ambos pasan (este issue no toca código, pero el CI lo exige)
```

## Riesgos y preguntas abiertas

- **`CLAUDE.md` contradice este issue** tras #87 («OpenCode sale del repo»). `AGENTS.md` es un
  **symlink a `CLAUDE.md`**, así que el criterio «AGENTS.md actualizado» y la corrección de la
  contradicción son **la misma edición**, en el mismo PR. Sin eso, el próximo fleet lee lo contrario
  de la verdad. Entra en alcance.
- El auditor vía pane es **más lento** que un subagente in-proceso y consume un pane de la sesión del
  dueño. Aceptado: es el precio de la invariante. El pane se cierra en el cierre del flow, y eso va
  al `trap` del propio guion (regla de #84 sobre estado inyectado fuera del repo).
- `.opencode/.gitignore` ya excluye `node_modules`, `package.json`, `package-lock.json`, `bun.lock`
  y a sí mismo — verificar que no excluye `agents/` antes de dar por bueno un `git status` limpio.
- **No se ha ejecutado un flow completo con este enjambre.** Este issue entrega los roles y la
  prueba de que cada canal responde; que un `/kelpie-flow` OpenCode llegue de punta a punta es
  trabajo de otro issue, y así lo dice el propio #91.
