# Diseño — #9 Tipos del subconjunto usado del API de herdr, validados contra el schema vendorizado

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-28

## Spec

Tipos a mano para el subconjunto de ~12 métodos de herdr que kelpie usa (de 91 totales), más un
test en `zig build test` que los contrasta estructuralmente contra `testdata/herdr-api.schema.json`
vendorizado — sin generador de código.

**Archivos que se tocan** (territorio `core-builder`, `area:rpc`):
- `src/herdr/types.zig` — nuevo. `AgentStatus`, `Pong`, `AgentInfo`, `PaneInfo`, `TabInfo`,
  `WorkspaceInfo`, `SessionSnapshot`, `Event`, más el test de conformidad contra el schema.
- `src/herdr/probe.zig:333` — el `test { _ = client; }` existente pasa a `test { _ = client; _ =
  types; }`, para que el runner (que no camina `@import`s transitivos — ver comentario en la línea
  330) descubra los tests de `types.zig`.

**No entra** (del issue, YAGNI ya recortado ahí):
- Generador de código a partir del schema.
- Cobertura de los 91 métodos — solo los ~12 que kelpie usa hoy: `ping`, `session.snapshot`,
  `agent.list`, `events.subscribe` (los cuatro que ya ejercita `probe.zig`) y el resto del
  vocabulario de tipos que esos cuatro necesitan (`AgentInfo`, `PaneInfo`, `TabInfo`,
  `WorkspaceInfo`, `SessionSnapshot`, `Pong`, eventos).
- Campos opcionales de `PaneInfo`/`TabInfo`/`WorkspaceInfo` más allá de los `required` del schema:
  el issue solo detalla el conjunto opcional de `AgentInfo` explícitamente; `TabInfo` y
  `WorkspaceInfo` no tienen ningún campo opcional en el schema (todas sus propiedades son
  `required`), y para `PaneInfo` ninguno de los ~12 métodos usados hoy consume un campo opcional
  suyo — se cubre con los `required`, y se amplía cuando un issue de UI lo necesite.
- Modelado tipado de `SessionSnapshot.layouts` (`PaneLayoutSnapshot`, anidado y no usado por
  ninguno de los ~12 métodos): el campo existe como `[]const std.json.Value` — satisface "el campo
  existe con ese nombre" (lo único que el test de conformidad exige de un `required`) sin modelar
  una jerarquía que nadie consume todavía.
- `ServerCapabilities` tipado dentro de `Pong.capabilities`: el issue solo pide el campo `capabilities?`
  presente; se tipa como `?std.json.Value` en vez de un struct nuevo — nadie de los ~12 métodos lee
  sus subcampos (`live_handoff`, `detached_server_daemon`).

## Firmas de API que se van a usar

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `AgentStatus` enum (`idle,working,blocked,done,unknown`) | `src/herdr/testdata/herdr-api.schema.json:6330-6338` (`schemas.success_response.$defs.AgentStatus`) | ✅ |
| `AgentInfo` required (`terminal_id,agent_status,workspace_id,tab_id,pane_id,focused,revision`) | `src/herdr/testdata/herdr-api.schema.json:6113,6228-6236` (`schemas.success_response.$defs.AgentInfo`) | ✅ |
| `AgentInfo` optional usados (`agent,display_agent,name,title,cwd,terminal_title,terminal_title_stripped,state_change_seq`) | `src/herdr/testdata/herdr-api.schema.json:6113-6227` (propiedades de `AgentInfo`, cada una `"type":[...,"null"]` o con `"default"`) | ✅ |
| `PaneInfo` required (mismos 7 campos que `AgentInfo`) | `src/herdr/testdata/herdr-api.schema.json:7394,7504-7511` (`schemas.success_response.$defs.PaneInfo`) | ✅ |
| `TabInfo` required (`tab_id,workspace_id,number,label,focused,pane_count,agent_status` — todos, sin opcionales) | `src/herdr/testdata/herdr-api.schema.json:9891,9919-9927` (`schemas.success_response.$defs.TabInfo`) | ✅ |
| `WorkspaceInfo` required (`workspace_id,number,label,focused,pane_count,tab_count,active_tab_id,agent_status`) | `src/herdr/testdata/herdr-api.schema.json:9930,9983-9992` (`schemas.success_response.$defs.WorkspaceInfo`) | ✅ |
| `SessionSnapshot` required (`version,protocol,workspaces,tabs,panes,layouts,agents`) | `src/herdr/testdata/herdr-api.schema.json:9814,9873-9881` (`schemas.success_response.$defs.SessionSnapshot`) | ✅ |
| `Pong` (inline en `ResponseResult.oneOf[0]`: `type:"pong",version,protocol,capabilities?`) | `src/herdr/testdata/herdr-api.schema.json:8624-8654` (`schemas.success_response.$defs.ResponseResult`) | ✅ |
| `EventKind` enum (incluye `pane_updated,pane_created,pane_closed,pane_agent_status_changed,workspace_created,workspace_closed,workspace_renamed,tab_created,tab_closed,tab_renamed,tab_moved,tab_focused`) | `src/herdr/testdata/herdr-api.schema.json:7018-7020` (`schemas.event.$defs.EventKind`; lista completa visible con `sed -n '7018,7045p'`) | ✅ |
| `request.oneOf` — métodos usados (`ping,session.snapshot,agent.list,events.subscribe`) | `src/herdr/testdata/herdr-api.schema.json:4429,4433,4577,4913,5633` (`schemas.request.oneOf[].properties.method.const`) | ✅ |
| `event.properties/{event,data}` required ambos (título `EventEnvelope`) | `src/herdr/testdata/herdr-api.schema.json:1211-1219` (`schemas.event.required` → `["event","data"]`) | ✅ |
| `std.json.parseFromSlice(T, allocator, s, options)` | `/usr/lib/zig/std/json/static.zig:73-83` | ✅ |
| Hook `pub fn jsonParse(allocator, source: anytype, options) !@This()` en un tipo custom (enum incluido) | `/usr/lib/zig/std/json/static.zig:258-260` (dispatch para `.@"enum"`); ejemplo de firma real en `/usr/lib/zig/std/json/hashmap.zig:21` | ✅ |
| Patrón de lectura de token de enum (`source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?)`, `std.meta.stringToEnum`, liberar `.allocated_string`) | `/usr/lib/zig/std/json/static.zig:262-268` (rama `.@"enum"` por defecto) y `:776-783` (`sliceToEnum`) y `:797-804` (`freeAllocated`) | ✅ |
| Falta de default en campo struct → `error.MissingField` si el campo no aparece y no tiene `= null`/default | `/usr/lib/zig/std/json/static.zig:785-792` (`fillDefaultStructValues`) | ✅ |

## Escenarios (Gherkin)

```gherkin
Escenario: zig build test falla si se renombra un campo requerido de AgentInfo
  Dado el checker `assertRequiredFieldsMatch(AgentInfo, required_list)` de types.zig
  Cuando se le pasa una copia de la lista `required` de AgentInfo con "pane_id" renombrado a "pane_id_renamed"
  Entonces el checker devuelve error.MissingRequiredField
  Y el mismo checker con la lista real (leída de testdata/herdr-api.schema.json) pasa sin error

Escenario: un agent_status futuro decodifica a .unknown sin error
  Dado el JSON {"status":"paused"}
  Cuando se parsea con std.json.parseFromSlice hacia un struct con campo AgentStatus
  Entonces el resultado es AgentStatus.unknown
  Y no se devuelve ningún error

Escenario: campos opcionales ausentes de AgentInfo quedan null
  Dado un JSON de AgentInfo que solo trae los 7 campos required
  Cuando se parsea con std.json.parseFromSlice(AgentInfo, gpa, bytes, .{.ignore_unknown_fields = true})
  Entonces name, title, display_agent, cwd, terminal_title, terminal_title_stripped, agent, state_change_seq son null (o su default)
  Y no se devuelve ningún error

Escenario: scripts/update-schema.sh regenera testdata y el test sigue verde
  Dado que scripts/update-schema.sh ya existe (de #8) y no cambia en este issue
  Cuando se corre `herdr api schema --json` contra un servidor en protocol 20 o protocol 21
  Entonces el test de conformidad de types.zig no asume un valor fijo de "protocol" en ningún assert
  Y por tanto sigue verde en ambos casos — este escenario se verifica por inspección del diseño (no
  hay fixture de protocol 21 disponible en esta máquina), documentado como riesgo abajo
```

## Riesgos y preguntas abiertas

- El cuarto escenario (protocol 20 y 21) no tiene una segunda fixture de schema disponible para
  correr de verdad — se verifica por construcción (ningún assert de `types.zig` fija `protocol ==
  20`) en vez de con una segunda corrida real. Si en el futuro cambia el *shape* de alguno de los
  `$defs` usados (no solo el número de protocolo), este test sí debe volver a fallar y eso es lo
  esperado.
- `Pong.capabilities` y `SessionSnapshot.layouts` quedan como `?std.json.Value` / `[]const
  std.json.Value` sin tipar — declarado arriba como corte YAGNI, no como hueco de investigación.
