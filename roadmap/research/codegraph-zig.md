# Expediente: codegraph (colbymchenry) en el enjambre de kelpie

**Fecha**: 2026-09-04 · **Modo**: incógnita técnica · **Estado**: propuesto, pendiente de aprobación humana
**Encargo**: `encargo-codegraph.md` (scratchpad, corrida de #91) · **Veredicto**: el issue de cableado **muere aquí** para kelpie (criterio de muerte del encargo, §Q1). Cero issues propuestos — deliberado, ver §Lente YAGNI.

## Qué se preguntó

Instalar y cablear **codegraph** (https://colbymchenry.github.io/codegraph/) al enjambre para que
builders y QA consulten símbolos en vez de leer archivos enteros, tras dos cuelgues medidos de la
capa de herramientas de OpenCode con la misma firma (coste `$0.00`, spinner girando): `read` de
`src/model/Store.zig` entero → bucle indefinido; relectura de `tool-output/` → 12 min colgado.
Cuatro preguntas a responder **ejecutando, no de memoria** (Q1–Q4 del encargo).

## Qué se ejecutó (evidencia)

1. `which codegraph` → no está en `PATH` (exit 1). `ls ~/.local/bin`, `~/.cargo/bin` (no existe),
   `npm ls -g`, `mise list` → **no instalado en ningún origen**. El encargo no suponía nada.
2. MCP logs de plume (`~/.cache/claude-cli-nodejs/-home-alejodelosrios-Documents-Sites-plume/mcp-logs-codegraph/*.jsonl`,
   3 intentos 2026-08-24/09-02) → todos `ENOENT: Executable not found in $PATH: "codegraph"`.
   Los dos `.mcp.json` están bien escritos; **lo que falta es el binario**, no la config:
   `smart-offices-app/.mcp.json` (`command: codegraph, args: [serve, --mcp]`) y
   `plume/.mcp.json` (idem + `"type": "stdio"`). Ambas formas son válidas para Claude Code.
3. Identidad del codegraph configurado: `serve --mcp` + tools `codegraph_search/context/callers/callees/impact/node/status`
   = **`@colbymchenry/codegraph`** (su README documenta exactamente ese bloque manual). Confirmado por el dueño 2026-09-04.
4. Versión e instalación medidas: `npx -y @colbymchenry/codegraph --version` → **`1.6.0`**
   (Node 26.8.1, `npm root -g` escribible). Orígenes: `npx @colbymchenry/codegraph` o
   `npm install -g @colbymchenry/codegraph`. Requisito: Node ≥ 18.
5. **Prueba de Zig (criterio de muerte), ejecutada en `/tmp/opencode/cg-probe/` — el repo no se tocó
   (`git status` limpio al cierre):**
   - Copia de `src/model/Store.zig` (**1946 líneas** medidas con `wc -l`, no 1800).
   - `codegraph init` → **"No files found to index"** (4.7 s).
   - `codegraph status` → **Files: 0, Nodes: 0, Edges: 0**.
   - `codegraph query "applySnapshot"` → **"No results found"**, contra ground truth
     `grep -c applySnapshot` = **61 ocurrencias**, definida en `Store.zig:176`.
   - Tabla de lenguajes del README (13: TS, JS, Python, Go, Rust, Java, C#, PHP, Ruby, C, C++,
     Swift/Kotlin básicos) — **sin Zig**. El "20+ lenguajes" del marketing no cambia lo medido.
6. Q2 (declaración MCP en OpenCode), verificada sin instalar nada:
   - Schema local `oc-schema.json` (scratchpad #91): `$defs/McpLocalConfig` exige `type: "local"` +
     `command` **array** (no string como en `.mcp.json` de Claude). Forma correcta:
     `{"mcp": {"codegraph": {"type": "local", "command": ["codegraph", "serve", "--mcp"], "enabled": true}}}`.
     `~/.config/opencode/opencode.json` hoy **no tiene sección `mcp`**; `.opencode/opencode.json` tampoco.
   - Docs oficiales `opencode.ai/docs/agents` (2026-09-02): las claves de `permission` casan por
     wildcard contra el nombre de herramienta, incluidos MCP (`"mymcp_*": "deny"`), y **se pueden
     sobreescribir por agente** (frontmatter `permission:`). El mecanismo existe; el prefijo exacto
     de herramienta (`<server>_*`) se confirmaría al registrar — hoy irrelevante (ver veredicto).
7. Q3 (coste): **inmedible para Zig porque no hay nada que indexar** (0 nodos). Referencias:
   lectura por rango vía `sed -n '1,110p'` = 5 ms a nivel bash; los 19 s / 12 min del encargo son
   de la capa de herramientas de OpenCode, no del disco. El parche vigente (rangos + juzgar por
   exit code) sigue siendo lo correcto.
8. Precedente u1App2: `smart-offices-app/.claude/agents/*.md` declaran `mcp__codegraph__*` y
   `plume/.claude/swarm-manifest.json:190-191` lo declara "Indexado sobre Go" — ambos stacks
   (TS, Go) **sí** soportados por 1.6.0. El valor existe allí, no aquí.
9. `kelpie/.claude/swarm-manifest.json:187` ya lo dice: "Sin CodeGraph (no está instalado en la máquina)".
   kelpie además **no tiene `.mcp.json`** (verificado) y su código es Zig + `scripts/` (bash, tampoco
   soportado) → valor cero incluso ignorando el criterio de muerte.

## Conclusión (lo que iría al issue, si hubiera)

- **Q1 — MUERTO con evidencia**: `@colbymchenry/codegraph@1.6.0` no indexa Zig (0/0/0 en 1946
  líneas, query contra 61 ocurrencias → vacío). **No se cablea nada en kelpie**: ni `mcp` en
  `.opencode/opencode.json`, ni `.mcp.json` en la raíz, ni `permission` por agente, ni skill.
- **Q2 — mecanismo verificado, sin uso**: la declaración y el gating por agente existen y están
  citados; quedan como referencia si un día codegraph soporta Zig (re-evaluar entonces, no antes).
- **Q3 — moot**: sin índice no hay comparativa; el parche de rangos sigue vigente.
- **Q4 — ninguno de los dos enjambres**: el problema (cuelgues OpenCode) es de la capa de
  herramientas; codegraph solo lo evitaría donde puede indexar, y en kelpie no puede.
- **Los dos `.mcp.json` rotos no los arregla ningún PR de kelpie** (viven en otros repos y su
  contenido es correcto): se arreglan instalando el binario a nivel máquina —
  `npm install -g @colbymchenry/codegraph` (o `npx @colbymchenry/codegraph` para el instalador
  interactivo). Nota: telemetría anónima por defecto (`codegraph telemetry off` o
  `CODEGRAPH_TELEMETRY=0`); los `.codegraph/` por proyecto + git hooks los crea `init`, no la instalación.
- **No improvisar sustituto** (orden explícita del encargo): se evaluó y descartó salir a buscar
  otro "codegraph" con Zig — el propio encargo lo prohíbe, y el parche vigente cubre la necesidad.

## Preguntas abiertas

1. (No bloqueante) Si codegraph publica soporte Zig en el futuro: re-evaluar con la misma prueba
   (`init` sobre `src/model/` + `query applySnapshot` contra `grep -c`). Criterio binario ya definido aquí.
2. (Dueño, fuera de kelpie) ¿Instalar el binario global para revivir plume + smart-offices-app?
   Es una decisión de máquina, no un issue del roadmap — no se crea issue.

## Lente YAGNI

**Cero issues propuestos, a propósito.** El criterio de muerte del encargo disparó con evidencia
ejecutada; crear un spike/feat "por si acaso" sería gastar builders, QA y auditor en un índice que
hoy devuelve 0 nodos sobre el 100% del código de kelpie. El corte aquí es gratis. Lo único vivo es
la línea de instalación para otros repos, y eso no es trabajo de este roadmap.

---

# Addendum 2026-09-04 (el dueño ordena: revivir en server + buscar alternativa Zig)

## Revival colbymchenry para plume / smart-offices-app: BLOQUEADO (server)

- Instalado localmente: `npm install -g @colbymchenry/codegraph` → `codegraph --version` = **1.6.0**.
  (`npm root -g` escribible, Node 26.8.1.)
- El dueño aclara que esos proyectos viven en el **server**: único host SSH `m2`
  (`manuels-macbook-pro:22`) → `ssh` = **Connection timed out**. Nada que instalar hasta que el
  server sea alcanzable. One-liner pendiente allí: `npm install -g @colbymchenry/codegraph`
  (requiere Node ≥ 18). Los `.mcp.json` no necesitan cambios (contenido válido; solo faltaba el binario).

## Alternativa Zig encontrada y MEDIDA: suatkocar/codegraph 0.2.5 (Rust, MIT)

Fuente: https://github.com/suatkocar/codegraph — único "codegraph" con `queries/zig.scm` real
(capturas `function_declaration`, `variable_declaration`, `call_expression` verificadas por lectura).
Todo lo de abajo ejecutado en `/tmp` (repo intacto, probes borrados al cierre):

- Instalación: tarball `codegraph-v0.2.5-x86_64-unknown-linux-gnu.tar.gz` (9.2 MB, binario 79 MB,
  sin dependencias). Vías `install.sh`/`brew`/`cargo` no probadas. **Vía `npx @suatkocar/codegraph`
  ROTA**: `NotFound: FileSystem.access` + cuelgue > 120 s — no usar el wrapper npm.
- `index` sobre copia de `Store.zig` (1946 líneas): **1 fichero, 329 nodos, 400 aristas en 402 ms**.
  `languages` → `zig — 1 files`.
- `query applySnapshot` → encuentra `applySnapshot (function) — Store.zig` (ranking keyword flojo,
  scores ~0.015 planos sin embeddings — esperado sin Ollama).
- **Caveat medido**: `impact applySnapshot` y `impact Store.zig` → 0 dependientes en probe de un
  solo fichero. Resolución de call-graph Zig sin verificar → pregunta abierta del spike.
- MCP `serve` (stdio, **sin** flag `--mcp`): handshake `initialize` OK (`serverInfo.name=codegraph,
  version=0.2.5`); `tools/list` = **44 tools**, incluyendo `codegraph_callers`, `codegraph_callees`,
  `codegraph_find_references`, `codegraph_query`, `codegraph_node`, `codegraph_impact`.
- **Colisión de binario**: ambos proyectos instalan un `codegraph` en `PATH` — mutuamente
  excluyentes bajo el mismo nombre. Convivencia = renombrar (p. ej. `codegraph-zig`) + ruta
  absoluta en el `command` del MCP. A decidir en el spike.
- Alternativas aparcadas sin probar (suatkocar ya funciona): `zls` vía LSP de OpenCode (no
  instalado; compatibilidad con Zig 0.16 desconocida), `ast-grep` (soporte Zig sin verificar),
  `ctags` (no instalado). Si el spike de suatkocar falla su criterio binario, estas son la
  escalera de fallback.

## Propuesta (requiere aprobación; no creado)

**Spike `type:spike`**: cablear suatkocar 0.2.5 solo al enjambre OpenCode de kelpie en un worktree:
`mcp` en `.opencode/opencode.json` con binario renombrado, `permission: {"codegraph-zig_*": ...}`
por agente builder/qa, índice sobre `src/` real. **Criterio binario**: `codegraph_callers` (vía MCP)
devuelve los llamadores reales de `applySnapshot` (ground truth: 61 ocurrencias `grep -c`,
definición `Store.zig:176`) en < 60 s tras `index` < 5 min; si falla, se para y se informa, sin
improvisar workaround en el mismo PR. Labels: `type:spike` sin `area:*` (tooling del
enjambre, lo ejecuta el PM en worktree; no toca `src/`).
