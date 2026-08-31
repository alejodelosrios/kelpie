# Diseño — #12 Store de agentes: snapshot + eventos → lista por urgencia, transiciones de estado observables

> Aprobado por: orquestador PM (/kelpie-flow) · 2026-08-31

## Spec

`src/model/Store.zig` (nuevo): fuente de verdad en memoria para el sidebar — mapa
`(device_id, pane_id) → Agent`, más el conjunto de `WorkspaceInfo` por dispositivo. Expone
`applySnapshot` (reemplazo total desde `session.snapshot`) y `applyEvent` (mutación incremental
desde `EventEnvelope`), una lista ordenada por urgencia, y observadores (`onChanged`,
`onTransition`) invocados síncronamente por el llamador.

**Archivos que se tocan** (territorio `core-builder`, `area:rpc`):
- `src/model/Store.zig` — todo lo de abajo.
- `build.zig` — apéndice al final, patrón `theme_css_mod`/`events_mod` (`build.zig:85-91,104-113`).
  **Nadie más toca ninguna otra línea de `build.zig`** — el issue #15 (`src/ui/app_shell.zig`)
  también apéndiza ahí esta ola; el segundo en mergear rebasa conservando los dos bloques nuevos
  (lección `lessons-learned.md` fila "Ola 2 M1 · Fleet / hotspots").

**No entra** (copiado del issue, más lo recortado por YAGNI):
- Persistencia en disco.
- Multi-dispositivo real: `device_id` es el string constante `"local"` en todo este issue; #34
  cambia qué valor se pasa, no la forma del mapa (por eso la clave ya es la tupla completa ahora).
- `layout_updated`, `pane_moved`, `pane_output_changed`, `pane_exited`, `pane_agent_detected`,
  `worktree_*`: fuera de la lista explícita del issue (`pane_created/updated/closed`,
  `pane_agent_status_changed`, `workspace_*`, `tab_*`). Recorte YAGNI: el Store existe para ordenar
  agentes por urgencia, no para el layout de paneles — eso es trabajo de un futuro consumidor de
  `layout_updated`. `applyEvent` ignora estos `EventKind` con un `switch` explícito (rama
  `else => {}`), nunca `unreachable`.
- **`pane_focused` sí entra**, corrección del orquestador sobre el primer borrador de este diseño:
  `Events.zig:75` ya suscribe `"pane.focused"`, así que el evento llega al Store igual que
  `pane_updated`, y `Agent.focused` es un campo que los consumidores (#18: "done del pane que
  estoy mirando no notifica") van a leer como verdad — dejarlo rancio entre snapshots rompería ese
  criterio en silencio.
- `workspace_moved`, `workspace_reordered`, `tab_moved`: mutan **orden** de listas, no identidad —
  fuera de alcance por la misma razón; se documentan como hueco abajo, no se tratan en silencio.
- El wiring real a `EventsClient.on_event`/`on_resynced` (los punteros a función que
  `Events.zig:92-93` exige) — vive donde exista el dueño de ambos objetos (issue de UI futuro,
  consumidor de `Events.zig` tal como el propio diseño de #10 dejó pendiente su dispatcher real).
  Este issue entrega `Store` como tipo puro, sin acoplarse a `EventsClient`.

## Modelo de datos

```zig
pub const Agent = struct {
    device_id: []const u8,   // dueño: Store (duplicado con gpa.dupe, liberado en remove/deinit)
    pane_id: []const u8,
    workspace_id: []const u8,
    tab_id: []const u8,
    status: types.AgentStatus,
    revision: u64,
    focused: bool,
    agent: ?[]const u8 = null,                    // "agent kind", p.ej. "claude"
    display_agent: ?[]const u8 = null,
    title: ?[]const u8 = null,
    terminal_title_stripped: ?[]const u8 = null,
    cwd: ?[]const u8 = null,

    /// title ?? terminal_title_stripped ?? agent ?? pane_id — regla del issue.
    pub fn displayTitle(self: Agent) []const u8 {
        return self.title orelse self.terminal_title_stripped orelse self.agent orelse self.pane_id;
    }
};
```

Todo `[]const u8` de `Agent` es una copia propia (`gpa.dupe(u8, ...)`, patrón ya verificado en
`src/herdr/client.zig:218`) — los datos de entrada (`types.SessionSnapshot`, `types.EventEnvelope`)
vienen de un `json.Parsed` que el llamador libera justo después de la callback
(`src/herdr/Events.zig:209,217`), así que el Store no puede quedarse con punteros a esa memoria.

**Concurrencia**: `Store` no lleva mutex propio. `Events.zig`'s `Dispatcher` ya marsalla
`on_event`/`on_resynced` fuera del hilo lector (`src/herdr/Events.zig:9-13`, doc-comment del
propio archivo); el contrato de `Store` es que `applySnapshot`/`applyEvent` se llaman **solo**
desde ese contexto ya despachado (el mismo hilo, en la práctica el hilo de UI). Documentado en el
doc-comment del struct, no hay guardia en runtime — igual que `Events.zig` no valida internamente
que su propio dispatcher lo cumpla.

## Firmas de API que se van a usar

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `pub fn HashMap(` (comptime K, V, Context, max_load_percentage) | `/usr/lib/zig/std/hash_map.zig:135` | ✅ |
| `pub fn initContext(allocator: Allocator, ctx: Context) Self` | `/usr/lib/zig/std/hash_map.zig:182` | ✅ |
| `pub fn deinit(self: *Self) void` | `/usr/lib/zig/std/hash_map.zig:211` | ✅ |
| `pub fn count(self: Self) Size` | `/usr/lib/zig/std/hash_map.zig:233` | ✅ |
| `pub fn iterator(self: *const Self) Iterator` | `/usr/lib/zig/std/hash_map.zig:239` | ✅ |
| `pub fn put(self: *Self, key: K, value: V) Allocator.Error!void` | `/usr/lib/zig/std/hash_map.zig:322` | ✅ |
| `pub fn fetchRemove(self: *Self, key: K) ?KV` | `/usr/lib/zig/std/hash_map.zig:358` | ✅ |
| `pub fn get(self: Self, key: K) ?V` | `/usr/lib/zig/std/hash_map.zig:367` | ✅ |
| `pub fn getPtr(self: Self, key: K) ?*V` | `/usr/lib/zig/std/hash_map.zig:374` | ✅ |
| `pub fn remove(self: *Self, key: K) bool` | `/usr/lib/zig/std/hash_map.zig:420` | ✅ |
| `pub const block = @import("sort/block.zig").block;` (estable) | `/usr/lib/zig/std/sort.zig:9` | ✅ |
| `pub fn block(comptime T, items: []T, context, comptime lessThanFn)` | `/usr/lib/zig/std/sort/block.zig:100` | ✅ |
| `gpa.dupe(u8, msg_val.string)` (patrón de copia propia, ya usado en el repo) | `src/herdr/client.zig:218` | ✅ |
| `gpa.free(self.message)` (patrón de liberación simétrica) | `src/herdr/client.zig:114` | ✅ |
| `pub const AgentStatus = enum {` (`idle,working,blocked,done,unknown`) | `src/herdr/types.zig:9` | ✅ |
| `pub const AgentInfo = struct {` | `src/herdr/types.zig:69` | ✅ |
| `pub const PaneInfo = struct {` (`pane_id,terminal_id,workspace_id,tab_id,focused,agent_status,revision`) | `src/herdr/types.zig:88` | ✅ |
| `pub const TabInfo = struct {` | `src/herdr/types.zig:98` | ✅ |
| `pub const WorkspaceInfo = struct {` | `src/herdr/types.zig:108` | ✅ |
| `pub const SessionSnapshot = struct {` | `src/herdr/types.zig:119` | ✅ |
| `pub const EventEnvelope = struct {` (`event: EventKind, data: json.Value`) | `src/herdr/types.zig:140` | ✅ |
| `pub const EventKind = enum {` | `src/herdr/types.zig:36` | ✅ |
| `theme_css_mod`/`events_mod` — patrón de módulo de test propio en `build.zig` | `build.zig:85-91,104-113` | ✅ |
| `Dispatcher` marsalla fuera del hilo lector (doc-comment) | `src/herdr/Events.zig:9-13` | ✅ |
| `EventCtx`/`ResyncCtx`: `parsed.deinit()` inmediatamente tras la callback | `src/herdr/Events.zig:209,217` | ✅ |

### Forma de `EventEnvelope.data` por `EventKind` (schema vendorizado, `schemas.event.$defs.EventData`)

Cada fila es un `oneOf` del schema — `applyEvent` hace `json.parseFromValue(Payload, gpa, envelope.data, .{.ignore_unknown_fields = true})` con el `Payload` correspondiente, reutilizando `types.PaneInfo`/`types.TabInfo`/`types.WorkspaceInfo`/`types.AgentStatus` donde el schema referencia esos mismos `$defs` (confirmado idéntico — ver nota abajo).

| `EventKind` | Payload (`{type, ...}`) | Fuente (`herdr-api.schema.json:línea`) | Verificada |
|---|---|---|---|
| `pane_created` | `{pane: types.PaneInfo}` | `src/herdr/testdata/herdr-api.schema.json:459-467` | ✅ |
| `pane_updated` | `{pane: types.PaneInfo}` | `src/herdr/testdata/herdr-api.schema.json:495-508` | ✅ |
| `pane_closed` | `{pane_id, workspace_id}` | `src/herdr/testdata/herdr-api.schema.json:472-483` | ✅ |
| `pane_agent_status_changed` | `{pane_id, workspace_id, agent_status: types.AgentStatus, agent: ?[]const u8, display_agent: ?[]const u8, title: ?[]const u8}` (`state_labels` ignorado, no entra) | `src/herdr/testdata/herdr-api.schema.json:663-704` | ✅ |
| `workspace_created`/`workspace_updated`/`workspace_metadata_updated` | `{workspace: types.WorkspaceInfo}` | `src/herdr/testdata/herdr-api.schema.json:87-95,100-108,116-124` | ✅ |
| `workspace_closed` | `{workspace_id}` (campo `workspace` nullable, no se usa) | `src/herdr/testdata/herdr-api.schema.json:135-150` | ✅ |
| `workspace_renamed` | `{workspace_id, label}` | `src/herdr/testdata/herdr-api.schema.json:160-176` | ✅ |
| `workspace_focused` | `{workspace_id}` | `src/herdr/testdata/herdr-api.schema.json:240-250` | ✅ |
| `tab_created` | `{tab: types.TabInfo}` | `src/herdr/testdata/herdr-api.schema.json:335-347` | ✅ |
| `tab_closed` | `{tab_id, workspace_id}` | `src/herdr/testdata/herdr-api.schema.json:352-366` | ✅ |
| `tab_renamed` | `{tab_id, workspace_id, label}` | `src/herdr/testdata/herdr-api.schema.json:368-386` | ✅ |
| `tab_focused` | `{tab_id, workspace_id}` | `src/herdr/testdata/herdr-api.schema.json:428-441` | ✅ |
| `pane_focused` | `{pane_id, workspace_id}` | `src/herdr/testdata/herdr-api.schema.json:498-516` | ✅ |

**Nota verificada**: `PaneInfo`/`TabInfo`/`WorkspaceInfo` del `$defs` de `schemas.event` tienen el
mismo array `required` que sus homónimos de `schemas.success_response` (comparación hecha campo a
campo con `python3 -c "json.load(...)"` sobre `herdr-api.schema.json`: los seis `required` son
idénticos), así que reusar los tipos de `types.zig` para parsear el `data` de los eventos es
seguro y no un supuesto — no cuenta como cita `archivo:línea` porque es una comparación
estructural, no una lectura de fuente única; se deja registrado aquí por si hace falta reproducirla.

## `applyEvent` — reglas de mutación

- `pane_created`/`pane_updated` → `upsertAgent`: busca `(local, pane.pane_id)`; si existe, actualiza
  `status/revision/focused/workspace_id/tab_id` (los únicos campos que `PaneInfo` trae) y dispara
  `onTransition` si `status` cambió; si no existe, lo crea con esos campos y el resto de `Agent` en
  default (`agent/title/...= null`) — cumple el criterio "un `pane_updated` de un pane desconocido
  lo crea".
- `pane_closed` → `fetchRemove((local, pane_id))`; si existía, libera sus strings con `gpa.free` y
  dispara `onChanged`. Pane desconocido: no-op (eventos fuera de orden no rompen).
- `pane_agent_status_changed` → igual que `pane_created/updated` pero solo toca
  `status/agent/display_agent/title` (no crea el pane si no existe — el schema no trae
  `workspace_id`/`tab_id` suficientes para un alta completa; no-op sobre pane desconocido).
- `pane_focused` → pone `focused=true` en `(local, pane_id)` y `false` en los demás agentes del
  mismo `device_id` (mismo patrón que `workspace_focused`/`tab_focused` abajo); pane desconocido:
  no-op. Dispara `onChanged` pero no `onTransition` (no cambia `status`) — no reordena
  `orderedAgents()` porque `focused` no entra en `urgencyRank`/el desempate.
- `workspace_created`/`workspace_updated`/`workspace_metadata_updated` → upsert en el mapa de
  workspaces por `(local, workspace_id)`.
- `workspace_closed` → remove por `workspace_id`.
- `workspace_renamed` → actualiza `label` si existe; no-op si no.
- `workspace_focused` → pone `focused=true` en ese workspace y `false` en los demás del mismo
  `device_id` (mismo patrón que un futuro `tab_focused`/`pane_focused`, pero acotado a lo que este
  issue cubre).
- `tab_created` → upsert en el mapa de tabs por `(local, tab_id)`.
- `tab_closed` → remove por `tab_id`.
- `tab_renamed` → actualiza `label`.
- `tab_focused` → mismo patrón que `workspace_focused`, acotado a tabs del mismo `workspace_id`.
- Cualquier otro `EventKind` (`layout_updated`, `pane_moved`, etc.) → rama `else => {}` explícita,
  nunca `unreachable` (regla dura del repo, camino de evento no es camino de error pero tampoco se
  asume exhaustivo a mano).

`applySnapshot` reemplaza los tres mapas (`agents`, `workspaces`, `tabs`) enteros a partir de
`SessionSnapshot.agents`/`.workspaces`/`.tabs`, liberando las entradas viejas primero — es un reset,
no un diff.

## Orden de urgencia y observadores

```zig
fn urgencyRank(status: types.AgentStatus) u8 {
    return switch (status) {
        .blocked => 0,
        .done => 1,
        .working => 2,
        .idle => 3,
        .unknown => 4,
    };
}
```

`orderedAgents(self: *Store, allocator, buf: []*const Agent) []const *const Agent` (o equivalente
con `std.array_list.Managed`, patrón ya verificado en `src/herdr/types.zig:341`) llena un slice de
punteros a las entradas del `HashMap` y lo ordena con `std.sort.block` usando un comparador
`lessThan(ctx, a, b) = urgencyRank(a.status) < urgencyRank(b.status) or (rank igual y a.revision >
b.revision)` — desempate por `revision` descendente, tal como pide el issue.

`ChangeObserver = struct { ptr: *anyopaque, onChangedFn: *const fn(ptr) void, onTransitionFn: *const
fn(ptr, agent: *const Agent, from: types.AgentStatus, to: types.AgentStatus) void }` — mismo patrón
`ptr`+fn-pointer que `Dispatcher`/`Sleeper` en `Events.zig:14-34`. `Store.addObserver` los agrega a
un `std.array_list.Managed(ChangeObserver)`; toda mutación que cambia el conjunto llama
`fireChanged()` al final, y toda mutación que cambia `status` de un `Agent` existente llama
`fireTransition(agent, from, to)` antes de `fireChanged()` — una sola vez por evento, según el
criterio de aceptación.

## Escenarios (Gherkin)

```gherkin
Escenario: transición de estado reordena y notifica una sola vez
  Dado un Store con 4 agentes tras applySnapshot (uno de ellos "working")
  Cuando llega un evento pane_updated que cambia ese agente a "blocked"
  Entonces orderedAgents() lo devuelve primero en la lista
  Y onTransition(agent, .working, .blocked) se disparó exactamente una vez

Escenario: pane_closed quita el agente; evento fuera de orden crea uno nuevo
  Dado un Store con un agente para pane_id "p1"
  Cuando llega pane_closed para "p1"
  Entonces orderedAgents() ya no lo incluye
  Cuando llega pane_updated para un pane_id "p9" nunca visto antes
  Entonces orderedAgents() incluye un nuevo agente para "p9" sin que el Store entre en error

Escenario: agent_status desconocido va al final
  Dado un evento pane_agent_status_changed con agent_status="paused" (valor no reconocido)
  Cuando se aplica al Store
  Entonces types.AgentStatus.jsonParse lo decodifica como .unknown (types.zig:16-24)
  Y ese agente aparece al final de orderedAgents()

Escenario: pane_focused mueve el foco sin reordenar por urgencia
  Dado un Store con 2 agentes "working", ninguno focused
  Cuando llega un evento pane_focused para uno de ellos (pane conocido)
  Entonces ese agente queda con focused=true y el otro con focused=false
  Y orderedAgents() no cambia de orden (focused no entra en urgencyRank)

Escenario: sin fugas
  Dado un ciclo applySnapshot → varios applyEvent → deinit()
  Cuando se corre bajo testing.allocator
  Entonces zig build test no reporta fugas
```

## Riesgos y preguntas abiertas

- La referencia del issue a `Models.swift:16-24` del fork de herdrm es solo la **regla** de orden
  (ya está en el propio cuerpo del issue: `blocked 0 → done 1 → working 2 → idle 3 → unknown 4`);
  el archivo no existe en este repo ni en el mirror pinneado — no se cita como fuente porque no es
  alcanzable, se cita la regla tal como el issue la escribió.
- `workspace_moved`/`workspace_reordered`/`tab_moved` (orden posicional, no identidad) quedan sin
  manejar en este issue — hueco declarado arriba en "No entra", no un olvido silencioso.
- El wiring real `Store` ↔ `EventsClient` (quién construye ambos y los conecta) es de un issue de
  UI futuro; aquí `Store` es un tipo puro sin esa dependencia, igual que `Events.zig` dejó su
  `Dispatcher` real fuera en #10.
