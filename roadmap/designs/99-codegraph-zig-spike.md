# Diseño — #99 spike: codegraph Zig project-local (suatkocar) solo para kelpie

> Aprobado por: humano (dueño) · 2026-09-04 — scope gate aprobado por chat ("adelante"); gate de diseño lo aprueba el PM: el issue viene enriquecido con expediente medido (`roadmap/research/codegraph-zig.md` + addendum) y criterio binario. Rama `feature/99-codegraph-zig-spike`.

## Spec

Cablear suatkocar/codegraph 0.2.5 al enjambre OpenCode de kelpie, project-local, y medir su criterio binario: el binario vive en `.tools/codegraph-zig` (descargado, nunca commiteado), el índice en `.codegraph/` (ignorado), la declaración MCP en `.opencode/opencode.json`, y el permiso `codegraph-zig_*` solo en `core-builder` y `qa`.

**Archivos que se tocan** (tooling del enjambre, lo ejecuta el PM; sin `area:*`, ningún builder — fuera de ambos territorios):
- `.gitignore` — añadir `.tools/` y `.codegraph/`
- `.opencode/opencode.json` — sección `mcp.codegraph-zig` (`type: local`, `command` array con ruta absoluta al binario del proyecto, `enabled: true`)
- `.opencode/agents/core-builder.md` — frontmatter `permission:` + `codegraph-zig_*: allow`
- `.opencode/agents/qa.md` — idem
- `roadmap/designs/99-codegraph-zig-spike.md` — este archivo

**No entra** (del issue):
- `codegraph init`, `git-hooks` y session-hooks (el `init` escribe `CLAUDE.md` e instala hooks: fuera)
- `.mcp.json` en la raíz (el enjambre Claude queda intacto)
- Tocar `PATH`, el binario global, `build.zig.zon`, `zig-pkg/` o el mirror de ghostty
- Embeddings/Ollama, indexar código externo, migrar otros proyectos
- Prohibido el wrapper `npx` (roto: `FileSystem.access` + cuelgue, medido en el addendum)

## Firmas y hechos que se van a usar

Ninguno se escribe de memoria. Cada fila la verificó el PM ejecutando `sed -n '<línea>p' <archivo>` (o el comando citado).

| Hecho usado | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| "Sin CodeGraph (no está instalado en la máquina)" — precede a este spike | `.claude/swarm-manifest.json:187` | ✅ `sed -n '187p'` |
| Base sin sección `mcp`; forma de `permission.external_directory` global | `.opencode/opencode.json:1-14` | ✅ `sed -n '1,14p'` |
| Forma del `permission` por agente (frontmatter) en core-builder | `.opencode/agents/core-builder.md:5-18` | ✅ `sed -n '5,18p'` |
| Idem en qa | `.opencode/agents/qa.md:5-18` | ✅ `sed -n '5,18p'` |
| `.gitignore` actual a extender | `.gitignore:1-4` | ✅ `sed -n '1,4p'` |
| Ground truth: def `pub fn applySnapshot…` | `src/model/Store.zig:176` | ✅ `sed -n '176p'` |
| Ground truth: 61 ocurrencias | `/usr/bin/grep -c applySnapshot src/model/Store.zig` → `61` | ✅ ejecutado |
| MCP local: `type` requerido + `command` **array**; `permission` casa por wildcard incl. MCP y se sobreescribe por agente | skill `customize-opencode` (cita `https://opencode.ai/config.json` como fuente de verdad si hay duda) | ✅ cargada en sesión |
| Tarball linux x86_64 0.2.5 (máquina `uname -m` = `x86_64`): URL + sha256 `b04ad3f0…9da36` | `gh release view v0.2.5 --repo suatkocar/codegraph` (asset `codegraph-v0.2.5-x86_64-unknown-linux-gnu.tar.gz`, 9214685 bytes) | ✅ ejecutado |
| MCP `serve` por stdio **sin** flag `--mcp`; 44 tools incl. `codegraph_callers` | expediente addendum (medido en `/tmp`, probes borrados) | ✅ heredado del expediente |
| Global intacto: `codegraph --version` = `1.6.0` en mise node | `which codegraph` + `codegraph --version`, ejecutados 2026-09-04 | ✅ ejecutado |

Cadena de activación: no aplica — este spike no cuelga de ningún callback/evento de producto; su "activación" es el PM ejecutando los comandos de cada escenario. Sin callbacks, sin observadores.

Obligaciones bajadas de `lessons-learned.md` (con su rastro):
- #91 comandos largos: `index`/builds a fichero, veredicto por exit code, nunca `cmd | tail` ni `grep` pelado (usar `/usr/bin/grep` o `awk`). Rastro: cada comando pegado con su `echo $?` en el reporte de FASE 5.
- #91 archivos grandes por rango: el Apply no lee `Store.zig` entero (1946 líneas / 76 KB > ambos cortes). Rastro: el diff no necesita ese archivo; el ground truth se cita por `sed -n` puntual.
- #84 instrumento que acusa: si el criterio MCP "falla", reproducir con segundo instrumento (JSON-RPC directo por stdio) antes de declarar muerte. Rastro: ambos intentos pegados en el issue al informar.
- #101 naturaleza de la denegación: si el auditor deniega mecánico con arreglo verificable, se arregla y se informa (no se escala por contador).

## Escenarios (Gherkin)

Uno por criterio de aceptación del issue. Los ejecuta el PM (spike de tooling); QA no escribe tests Zig — no hay código de producto — y verifica el diff + reproduce el criterio MCP.

```gherkin
Escenario 1 — global intacto:
  Dado el binario global codegraph 1.6.0 instalado vía mise
  Cuando ejecuto `codegraph --version` y `which codegraph`
  Entonces version es 1.6.0 y la ruta no apunta a `.tools`
```

```gherkin
Escenario 2 — nada versionado:
  Dado el spike ejecutado en el checkout
  Cuando ejecuto `.tools/codegraph-zig --version`, `git ls-files .tools` y `git status --porcelain`
  Entonces version es 0.2.5, `git ls-files .tools` es vacío y el porcelain no lista `.tools/` ni `.codegraph/`
```

```gherkin
Escenario 3 — index:
  Dado el binario del proyecto en `.tools/codegraph-zig`
  Cuando indexo `src/` real midiendo tiempo
  Entonces termina en < 5 min y `languages` lista `zig`
```

```gherkin
Escenario 4 — criterio binario MCP:
  Dado el índice del escenario 3
  Cuando vía MCP (stdio del binario del proyecto) pido `tools/list` y `callers("applySnapshot")` midiendo tiempo
  Entonces `tools/list` contiene `codegraph_callers` y callers devuelve ≥1 llamador real consistente con el ground truth (61 ocurrencias, def `Store.zig:176`) en < 60 s
  Y si falla: se para, se informa en el issue, sin workaround en el mismo PR
```

```gherkin
Escenario 5 — verde mecánico:
  Dado el diff del spike (solo los 4 archivos listados)
  Cuando ejecuto `zig build` y `zig build test` (a fichero, por exit code)
  Entonces ambos devuelven 0
```

```gherkin
Escenario 6 — QA del spike:
  Dado el diff commiteado y el diseño
  Cuando QA revisa territorio (solo tooling OpenCode), citas y reproduce el escenario 4
  Entonces cubre cada escenario con verificación o guion, con el sabotaje que vio cada comprobación en rojo donde aplique
```

## Riesgos y preguntas abiertas

- Prefijo real de herramienta MCP (`codegraph-zig_*` supuesto por wildcard): se confirma al registrar con `tools/list` (nota del propio issue). Si el prefijo difiere, el `permission` se corrige al real — cambio mecánico, no de spec.
- Resolución del call-graph Zig sin verificar (caveat del addendum: `impact` dio 0 en probe de un fichero): es exactamente lo que el criterio binario mide; si `callers` no devuelve llamadores reales, el spike MUERE y se informa.
- La sesión OpenCode viva no recarga `opencode.json` (se carga al arrancar): la verificación MCP del escenario 4 se hace por JSON-RPC directo contra el stdio del binario (lo mismo que haría el cliente MCP); la activación dentro de la TUI queda para la siguiente sesión con restart.
- `codegraph-zig --version`: formato de salida sin verificar hasta ejecutar (el criterio pide "es 0.2.5" — se acepta `0.2.5` contenido en la salida).
