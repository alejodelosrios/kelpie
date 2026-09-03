# Expediente: agentes OpenCode del enjambre de kelpie

**Fecha**: 2026-09-03 · **Modo**: feature · **Estado**: propuesto, pendiente de aprobación humana

## Qué se preguntó

Montar la contraparte OpenCode del enjambre: agentes `core-builder`, `ui-builder`, `docs-writer`,
`qa`, `auditor`, fallbacks y PM, **basados en los de Claude** (`.claude/builders/`,
`.claude/agents/`), de modo que un fleet pueda correr con builders de OpenCode. La discusión de
**qué LLM va en cada rol** queda para la ejecución del issue, no para este expediente.

## Qué se ejecutó (evidencia)

1. `ls ~/.config/opencode/` → existe `opencode.json` global; **no** existe `agent(s)/` global.
2. `head -50 ~/.config/opencode/opencode.json` → ya hay providers configurados: `ollama` (local),
   `mimo` (`baseURL: https://token-plan-sgp.xiaomimimo.com/v1`, modelos `mimo-v2.5-pro` y
   `mimo-v2.5` con `limit.context: 1048576`) y la sesión actual corre `opencode-go/kimi-k3`.
   **La discusión de modelos tiene material real con qué trabajar.**
3. Lectura íntegra de las fuentes del enjambre actual:
   - `.claude/builders/core-builder.md` (111 líneas), `ui-builder.md` (95), `docs-writer.md` (34)
   - `.claude/agents/auditor.md` (50, `model: opus`), `qa.md` (41, `model: sonnet`),
     `core-builder-fallback.md` (22), `ui-builder-fallback.md` (22)
   - `.claude/swarm-manifest.json` (198) — incluye la historia del A/B de #84/#85
   - `scripts/kelpie-builder` (62) — el arnés actual: `claude --print --append-system-prompt <rol>`
   - `.claude/commands/kelpie-fleet.md` (288), `AGENTS.md` (93)
4. `gh label list` → existen `area:*`, `type:chore` y los demás labels del formato.
5. `gh issue view 85` → confirmado: **#85 fue la migración DE OpenCode A Claude Code** como arnés de
   los builders (cerrado). Este issue es el camino de vuelta, con otra arquitectura.
6. `git status` → rama `develop` limpia salvo `.opencode/` sin trackear (las dos skills creadas
   hoy, que este issue vendría a completar).

## Hallazgo central: por qué #85 no bloquea esto

`swarm-manifest.json:6` y `scripts/kelpie-builder:11-20` documentan los **tres fallos de arnés**
que expulsaron a OpenCode en #84:

| Fallo en #84 (arnés `opencode run` headless) | Por qué no aplica al diseño propuesto |
|---|---|
| `opencode run` no tiene memoria entre invocaciones → rondas de corrección imposibles | Los agentes se invocan con la **herramienta `task` dentro de una sesión viva del PM**: la ronda de corrección reanuda la misma sesión del subagente (`task_id`), con todo su contexto. El PM ve el diff completo en cada ronda. |
| OpenCode bufferea stdout fuera de TTY → Apply envuelto en `script -qefc`, progreso invisible | No hay stdout que vigilar: la herramienta `task` devuelve el mensaje final del subagente directamente al PM. La vigilancia es el `git status` del worktree, igual que hoy. |
| El builder no veía las skills del repo | Resuelto hoy mismo: `.opencode/skills/kelpie-issue` y `kelpie-research` ya existen, y `zig-libghostty` + `omarchy-app` se copian a `.opencode/skills/` como parte del alcance. |

Conclusión: #85 descalificó `opencode run` **como proceso headless lanzado por un PM de Claude**.
No dice nada contra agentes OpenCode **in-proceso** lanzados por un PM de OpenCode.

## Diseño propuesto (lo que iría al issue)

### Archivos a crear (17 nuevos)

Basados en los de Claude, cuerpo de rol **calcado** (el contrato de citas, las fuentes de verdad,
los gotchas de la máquina y las reglas duras son independientes del motor):

| Archivo OpenCode | Basado en | Frontmatter |
|---|---|---|
| `.opencode/agents/core-builder.md` | `.claude/builders/core-builder.md` | `mode: subagent` · `model:` a discutir |
| `.opencode/agents/ui-builder.md` | `.claude/builders/ui-builder.md` | idem |
| `.opencode/agents/docs-writer.md` | `.claude/builders/docs-writer.md` | idem |
| `.opencode/agents/qa.md` | `.claude/agents/qa.md` | idem |
| `.opencode/agents/auditor.md` | `.claude/agents/auditor.md` | `mode: subagent` · **nunca se abarata** |
| `.opencode/agents/core-builder-fallback.md` | `.claude/agents/core-builder-fallback.md` (adaptada la línea "lee `.claude/builders/...`" → "lee `.opencode/agents/core-builder.md`") | idem |
| `.opencode/agents/ui-builder-fallback.md` | `.claude/agents/ui-builder-fallback.md` | idem |
| `.opencode/agents/pm.md` | rol PM extraído de `.claude/commands/kelpie-flow.md` + `kelpie-fleet.md` (gates, verificación `sed -n` del contrato de citas, lectura del `git diff` real, escritura de ledgers) | `mode: primary` |
| `.opencode/skills/zig-libghostty/SKILL.md` | `.claude/skills/zig-libghostty/SKILL.md` (copia; el frontmatter de skill ya es compatible) | — |
| `.opencode/skills/omarchy-app/SKILL.md` | `.claude/skills/omarchy-app/SKILL.md` | — |
| `.opencode/opencode.json` (nuevo) | — | `"$schema"`, sin sección `provider` (los providers viven en el global) |
| `.opencode/commands/kelpie-flow.md` | `.claude/commands/kelpie-flow.md` — adaptado: builders/qa/auditor se lanzan con la herramienta `task` (in-proceso, memoria por `task_id`) en vez de `scripts/kelpie-builder`; reconoce el **prefijo de procedencia** del fleet (los gates de scope y diseño los aprueba el orquestador por el chat del pane; el gate humano es solo el merge); mantiene el fail-safe de ≥2 issues → redirige al fleet | comando estándar |
| `.opencode/protocol.md` | **Protocolo de comunicación del enjambre OpenCode** (nuevo, canónico). Fuentes: canales 1-2 de `.claude/commands/kelpie-fleet.md:54-166`, canales 3-4 de `AGENTS.md:78-88` + contratos de reporte de `.claude/builders/*.md` | — |

**No se crea**: `.opencode/commands/kelpie-fleet.md` — el orquestador de olas sigue siendo Claude
(el caso de uso es *fleet mixto*: orquestador Claude → PMs OpenCode). Si un día se quiere un fleet
puro-OpenCode, es un issue posterior.

**No se toca**: `.claude/` (el enjambre Claude sigue siendo el de referencia), `build.zig.zon`,
`scripts/kelpie-builder` (arnés Claude Code; un equivalente OpenCode queda explícitamente fuera —
ver YAGNI).

### El caso de uso que lo justifica: fleet mixto Claude/OpenCode

Cadena de tres niveles de delegación, cada uno con su mecanismo natural:

```
Claude Code (orquestador fleet, en su pane)
  → herdr agent start flow-N --kind opencode --pane <nuevo>     (nivel 1)
OpenCode como PM del flow <N> (pane propio, worktree propio)
  → herramienta task → core-builder / qa / auditor in-proceso   (nivel 2 = este issue)
OpenCode PM → agent_status done/blocked/idle
  → el orquestador lo lee con herdr agent read y sigue la ola   (nivel 3)
```

- **Nivel 1 — verificado el 2026-09-03**: un agente lanzó a otro en un pane hermano con
  `herdr agent start flow-worker --kind claude`, le delegó una tarea con `agent prompt --wait` y
  leyó su respuesta exacta con `agent read`. El mecanismo es simétrico (`--kind opencode` está en
  la lista de kinds soportados por el binario instalado, herdr 0.8.2).
- **Nivel 3 — verificado el 2026-09-03**: ping `wA:p9` (OpenCode) → `wA:p5` (Claude) con
  `agent prompt --wait`; la respuesta ("pong 11:52:05 wA:p5") volvió por el transcript del pane y
  el estado `idle` marcó el fin del turno.
- **Nivel 2 — es este issue**: sin `.opencode/agents/`, el PM de OpenCode improvisaría los roles en
  cada flow.

Dos asimetrías reales que la ejecución tiene que resolver (no bloquean):

1. **Protocolo de procedencia** (fuente: `.claude/commands/kelpie-fleet.md:73-82`). Un PM que
   recibe `/kelpie-flow <N>` a secas cree que lo lanzó un humano y **se detiene en el scope gate**.
   El orquestador debe enviar el prefijo de procedencia ("te lanza el fleet, los gates los apruebo
   yo por este chat"), y el `kelpie-flow` de OpenCode debe **reconocerlo** — eso se escribe
   explícitamente en el comando.
2. **Verificación del contrato de citas**: el `pm.md` ordena ejecutar `sed -n` sobre cada fila de
   la tabla del builder exactamente igual que el PM Claude (`AGENTS.md:78-80`). Es `sed`, no magia
   del modelo — pero hay que escribirlo explícito para que ningún PM se lo salte.

### Protocolo de comunicación (canónico, descubrible desde cada rol)

El fleet mixto tiene **cuatro canales distintos**, y cada agente solo conoce el suyo a menos que el
contrato se lo diga. La pérdida de información típica: un builder `blocked` esperando un permiso y
el orquestador enterrándose solo si alguien lee el pane. Por eso el protocolo es **un documento**,
no una costumbre:

| Canal | Quién habla | Mecanismo | Qué NO puede perderse |
|---|---|---|---|
| 1. Orquestador → PM | Claude → pane OpenCode | `herdr agent prompt` | prefijo de procedencia, issue asignado, worktree |
| 2. PM → orquestador | OpenCode → Claude | `agent_status` + mensaje en su transcript | gates que necesitan aprobación, reporte final, preguntas abiertas |
| 3. PM → builders/qa/auditor | OpenCode → subagentes | herramienta `task` (mismo proceso) | prompt con territorio, diseño aprobado, motivo de la ronda de corrección |
| 4. Builder → PM | subagente → OpenCode | mensaje final del `task` | **tabla de citas completa**, archivos tocados, lo no hecho + motivo, sabotajes de tests |

Regla de oro del protocolo (va literal en `.opencode/protocol.md`):

> **Nada se transmite solo de voz.** Todo gate, reporte o pregunta queda también escrito donde
> persiste: el reporte del builder en su mensaje final, el del PM en el issue o en
> `roadmap/designs/`, los ledgers en `CONCERNS.md` / `lessons-learned.md`. Un pane se puede
> cerrar; lo que no está escrito se pierde.

Y la parte **descubrible**: cada uno de los 8 agentes + el comando `kelpie-flow` lleva en su
primera sección tras el frontmatter una línea idéntica de una frase, grepeable:

```markdown
> **Protocolo de comunicación**: `.opencode/protocol.md` — léelo antes de tu primer reporte.
> Tu canal: <canal que aplica a este rol>. Tu contrato de entrega: <sección del protocolo>.
```

| Agente | Su canal |
|---|---|
| `pm.md` | los 4: es el único que habla por todos; el protocolo ES su manual |
| `core-builder.md` / `ui-builder.md` | canal 4 (reporte al PM con tabla de citas); recibe por canal 3 |
| `docs-writer.md` | canal 4 (reporte + afirmaciones no verificadas); recibe por canal 3 |
| `qa.md` | canal 4 (cobertura Gherkin + salida real de tests; nunca arregla producción) |
| `auditor.md` | canal 4 (veredicto binario + hallazgos `archivo:línea`); nunca habla con builders |
| fallbacks | igual que su builder + "el motivo del fallo anterior te llega por canal 3" |
| `commands/kelpie-flow.md` | embebe la misma referencia: al arrancar, el PM lee el protocolo |

Verificación mecánica del criterio de aceptación:
`grep -l "protocol.md" .opencode/agents/*.md .opencode/commands/*.md` debe listar los 9 archivos.

### Decisiones de traducción Claude → OpenCode (ya verificadas contra el schema)

- `tools: Read, Edit, Write, Glob, Grep, Bash` (Claude) → `permission:` por agente (OpenCode):
  `read/glob/grep: allow`, `edit: allow`, `bash: allow` en builders y qa; el auditor igual salvo
  `edit: deny` (Claude lo restringía a Read/Glob/Grep/Bash; en OpenCode `read` es la herramienta de
  lectura, no hay que enumerarla aparte).
- `model: opus` / `model: sonnet` (Claude) → **a discutir en la ejecución** (ver abajo).
- Los fallbacks de Claude delegan leyendo el rol completo del builder; los de OpenCode harán lo
  mismo apuntando a la copia `.opencode/agents/`.
- `pm.md` es el único cuerpo que no existe como archivo suelto en el mundo Claude (vive dentro de
  los comandos): se extrae la parte de PM (FASE 4-8 del flow, verificación, gates, ledgers), no la
  de orquestador de panes.

### La pregunta que se discute en la ejecución: LLM por rol

Material verificado en la máquina (punto 2 de evidencia):

- `opencode-go/kimi-k3` — el que corre esta sesión; candidato natural de builders.
- `mimo/mimo-v2.5-pro` y `mimo/mimo-v2.5` — ya configurados globalmente con contexto 1M; el
  enjambre Claude los usa para builders y docs-writer respectivamente.
- `ollama` local — tres modelos pequeños; candidato de docs-writer si se quiere coste cero.
- Anthropic vía suscripción — ¿disponible como provider en OpenCode en esta máquina? **Pregunta
  abierta a resolver en la ejecución** (se mira con `opencode models` / el auth de OpenCode).

Invariante que NO se discute (heredada del AGENTS.md): **el auditor no se abarata** — sea cual sea
el modelo, es el más capaz disponible en OpenCode.

## Qué quedó como pregunta abierta

1. ¿Qué providers de Anthropic/OpenAI hay autenticados en OpenCode en esta máquina? (se responde
   ejecutando `opencode models`, no de memoria).
2. ¿`mode: primary` para `pm` es el encaje correcto para que el usuario lo elija con Tab, o mejor
   dejarlo `subagent` y que el orquestador humano sea el PM? (decisión de UX, sin impacto técnico).
3. ~~¿Se quieren comandos `.opencode/commands/kelpie-flow.md` / `kelpie-fleet.md`?~~ **RESUELTA el
   2026-09-03**: entra `kelpie-flow` (el escenario fleet mixto lo exige: el orquestador Claude debe
   poder decirle al pane simplemente "/kelpie-flow <N>"); queda fuera `kelpie-fleet` para OpenCode
   (el orquestador de olas puede seguir siendo Claude perfectamente).

## Lente YAGNI

- **Entra**: los 8 agentes, el comando `kelpie-flow`, el protocolo `.opencode/protocol.md`, las 2
  skills de stack, el `opencode.json` de proyecto, el smoke test.
- **No entra**: `kelpie-fleet` para OpenCode (el orquestador de olas sigue siendo Claude), lanzador
  `scripts/kelpie-builder` equivalente (el arnés headless es exactamente lo que #85 descalificó; no
  recrearlo sin evidencia de necesidad), migración del fleet a OpenCode (el fleet Claude sigue
  siendo el camino principal; esto habilita la alternativa, no la impone).
