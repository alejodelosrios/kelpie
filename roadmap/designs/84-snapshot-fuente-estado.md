# Diseño — #84 Estado en tiempo real: el snapshot es la única fuente fiable de `agent_status`

> Aprobado por: orquestador PM (/kelpie-flow, lanzado por /kelpie-fleet) · 2026-09-01 · rama `fix/84-snapshot-fuente-estado`
>
> El gate humano de este issue es el **merge**, con el refuerzo de verificación que el humano fijó
> al aprobar el plan de olas: gate con entorno saneado, cronómetro en los tres sentidos, sesión
> larga, y los tests de debounce y no-solapamiento.

## Spec

Los eventos de herdr dejan de ser fuente de `agent_status` y pasan a ser **señal de que algo
cambió**; la verdad la da siempre `session.snapshot`, pedido con debounce de 100 ms, coalescado,
sin solaparse, y descartado sin repintar si no cambió nada que el sidebar pinte.

**Archivos que se tocan** (secuenciado: core primero, verificar, commitear, luego ui):

| Builder | Archivo | Qué cambia |
|---|---|---|
| `core-builder` | `src/model/Store.zig` | `upsertAgent` deja de tocar `status` y desaparece la guarda de `unknown` de #81; `applySnapshot` gana la guarda de no-op por huella |
| `core-builder` | `src/herdr/Events.zig` | `EventsClient` gana un hilo trabajador de resync y `requestResync()` |
| `ui-builder` | `src/ui/herdr_link.zig` | `onEvent` programa el resync con debounce de 100 ms vía `glib.timeoutAddOnce` |

**No entra** (del issue, más el recorte YAGNI):
- Suscripción por pane a `pane.agent_status_changed` (opción A).
- Sondeo ciego sin eventos (opción C).
- `build.zig.zon` y el commit pinneado de ghostty.
- Alta instantánea de un agente nacido con kelpie ya conectado (el rebote lo cubre de facto,
  pero no es criterio).
- **El handler `pane_agent_status_changed` de `Store.applyEvent` (`Store.zig:271-294`) se queda
  como está.** No es contradicción: `subscription_types` (`Events.zig:73-95`) **no lo incluye**,
  así que en producción no llega nunca. Borrarlo ensancharía el diff y rompería sus tests para
  quitar código inalcanzable. El criterio del issue está acotado a `upsertAgent`, y así se cumple.

## Las dos preguntas abiertas del issue — MEDIDAS, no supuestas

Medido contra la sesión real (herdr 0.8.2, 14 panes / 7 agentes / snapshot de 17 229 B),
20 peticiones, conexión nueva por petición igual que `client.request`:

| | valor |
|---|---|
| `session.snapshot` | `min 17 ms · p50 28 ms · p95 105 ms · max 115 ms` |

→ Debounce 100 ms + p95 105 ms ≈ **205 ms**; peor caso medido ~215 ms. Cabe en los 500 ms con
margen de 2×. **El debounce queda fijado en 100 ms.**

Segunda pregunta, sonda de 33 s sobre la misma sesión suscrita a los 24 tipos de `subscription_types`:

| | valor |
|---|---|
| eventos de replay (<2 s) | 64 |
| eventos en vivo (>2 s) | 30 |
| de esos, que **cambiaron** la huella del sidebar | **0** |
| que **no** la cambiaron | **30** (`pane_updated` ×50 en total, `pane_agent_detected` ×14) |

→ **Sí, herdr emite eventos sin que el snapshot cambie, y es la norma, no la excepción.**
`pane.updated` se dispara con la salida del terminal, ~1/s en reposo.

### La consecuencia que obliga a una guarda

Sin defensa, la opción B cambia un bug de estado rancio por una regresión permanente: cada evento
acabaría en `session.snapshot` → `applySnapshot` → `fireChanged` → `Sidebar.refresh()`, que hace
`splice(0, old_n, …)` (`src/ui/sidebar.zig:317-366`) — **destruye y reconstruye todas las filas,
~1 vez por segundo, para siempre, sin que nada haya cambiado.**

Defensa, en `applySnapshot`: se calcula una **huella** de lo que el sidebar pinta; si es idéntica a
la anterior, se sale **antes** de mutar el Store y sin disparar `fireChanged`. La petición se paga
igual —no hay forma de saber que sobra sin preguntar—, pero el churn de UI desaparece.

**Campos de la huella** (hash Wyhash por fila, combinado con suma envolvente para que sea
independiente del orden del mapa, más el número de filas):

- `snapshot.agents[]`: `pane_id`, `agent_status`, `workspace_id`, `tab_id`, `focused`,
  `state_change_seq`, `agent`, `display_agent`, `title`, `terminal_title_stripped`, `cwd`
- `snapshot.workspaces[]`: `workspace_id`, `label`, `number`, `focused`, `agent_status`

**Excluido a propósito: `revision`.** Es el campo que sube con cada byte de salida del terminal —
es exactamente el ruido que estamos filtrando. Consecuencia declarada, no escondida: `lessThan`
(`Store.zig:682-686`) lo usa de **desempate por recencia dentro del mismo estado**, así que un cambio
que solo mueve `revision` no reordena el sidebar hasta el siguiente repintado real. Es un
desempate cosmético; pagar 1 reconstrucción/s por él sería peor negocio, y filas que saltan solas
bajo el cursor tampoco son mejor UX. **Va a `CONCERNS.md`** para que el dueño de #16 pueda objetar.

`terminal_title` también queda fuera (cambia con el prompt); `terminal_title_stripped` sí entra
porque el sidebar lo pinta en el subtítulo (`Agent.displayTitle`, `Store.zig:32-34`).

## Arquitectura del resync

El resync **no puede correr en el hilo de UI**: `client.request` bloquea hasta
`default_read_timeout_ms` y ya medimos un p95 de 105 ms. Regla dura del repo: *nunca bloquear el
hilo de UI*. Tampoco puede correr en el hilo lector, que está bloqueado dentro de `takeLine`.

Por eso un **tercer hilo, trabajador de resync**, dueño de `EventsClient`:

```
hilo de UI            hilo trabajador                 hilo lector
-----------           ---------------                 -----------
onEvent                                                takeLine → deliverEvent
  └ timeoutAddOnce(100ms) ─┐                             └ dispatcher.invoke → onEvent
                           ▼
                     requestResync()
                       └ if (!pending.swap(true)) sem.post()
                                    │
                                    ▼
                              sem.wait()
                              pending.store(false)
                              resync()  ← client.request + parse
                                └ dispatcher.invoke → onResynced → applySnapshot
```

Los dos criterios de concurrencia salen de la **estructura**, no de banderas que haya que recordar:

- **Coalescencia:** `pending.swap(true)` — mientras haya un resync pendiente no se emite otro
  permiso, así que N eventos en la ventana producen **una** petición.
- **No solapamiento:** un único hilo trabajador, secuencial. Un segundo aviso durante un resync en
  vuelo deja `pending = true` y se atiende al terminar — se encola, nunca se solapa.

**Parada limpia:** `stop()` marca `stopping`, hace `pending.store(true)` + `sem.post()` para
despertar al trabajador, y lo `join`ea antes de tocar el hilo lector. El trabajador comprueba
`stopping` justo al despertar.

## Firmas de API que se van a usar

Ninguna escrita de memoria. Cada fila la verificó el PM con `sed -n`/`awk` sobre la fuente.

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `g_timeout_add_once(p_interval: c_uint, p_function: glib.SourceOnceFunc, p_data: ?*anyopaque) c_uint` | `…/gobject-0.3.2-…/src/glib2/glib2.zig:24428` | ✅ |
| `pub const timeoutAddOnce = g_timeout_add_once;` | `…/src/glib2/glib2.zig:24429` | ✅ |
| `pub const SourceOnceFunc = *const fn (p_user_data: ?*anyopaque) callconv(.c) void;` | `…/src/glib2/glib2.zig:25660` | ✅ |
| `Io.Semaphore.wait(s: *Semaphore, io: Io) Io.Cancelable!void` | `/usr/lib/zig/std/Io/Semaphore.zig:18` | ✅ |
| `Io.Semaphore.post(s: *Semaphore, io: Io) void` | `/usr/lib/zig/std/Io/Semaphore.zig:34` | ✅ |
| `pub const Semaphore = @import("Io/Semaphore.zig");` | `/usr/lib/zig/std/Io.zig:49` | ✅ |
| `client.request(gpa, io, socket_path, method, params, read_timeout_ms, rpc_err) !Response` | `src/herdr/client.zig:170-178` | ✅ |
| `EventsClient.resync(self) !void` | `src/herdr/Events.zig:177` | ✅ |
| `types.AgentInfo` incluye `state_change_seq: u64 = 0` | `src/herdr/types.zig:85` | ✅ |
| `types.SessionSnapshot{ workspaces, tabs, panes, agents, … }` | `src/herdr/types.zig:119-131` | ✅ |
| `Store.applySnapshot(self, snapshot) !void` | `src/model/Store.zig:171` | ✅ |
| `upsertAgent(self: *Store, pane: types.PaneInfo) !void` | `src/model/Store.zig:618` | ✅ |
| `fn lessThan(_, a, b) bool` desempata por `a.revision > b.revision` | `src/model/Store.zig:682-686` | ✅ |
| `Sidebar.refresh` → `gio.ListStore.splice(…, 0, old_n, …)` | `src/ui/sidebar.zig:364` | ✅ |
| `glib.idleAddOnce` (patrón ya usado por el dispatcher) | `…/src/glib2/glib2.zig:20816` | ✅ |

`std.Thread.ResetEvent` **no existe** en Zig 0.16 (`/usr/lib/zig/std/Thread.zig` no lo declara):
las primitivas de sincronización viven bajo `std.Io` (`Io.Mutex` en `Io.zig:1587`,
`Io.Condition` en `Io.zig:1653`, `Io.Semaphore` en `Io.zig:49`). Por eso el diseño usa
`Io.Semaphore` y no lo que "se recuerda" de versiones anteriores.

## Escenarios (Gherkin)

```gherkin
Escenario 1: un agente que se bloquea aparece arriba y con glifo  [criterio 1]
  Dado kelpie abierto contra un herdr real, sin tocar la ventana
  Cuando un agente pasa a `blocked` en herdr
  Entonces en menos de 500 ms su fila muestra el glifo de bloqueado
  Y aparece en primer lugar del sidebar

Escenario 2: un agente que vuelve a idle PIERDE el glifo  [criterio 2 — el que falló en #81]
  Dado un agente pintado como `blocked` en el sidebar
  Cuando vuelve a `idle` en herdr
  Entonces en menos de 500 ms su fila ya NO muestra el glifo de bloqueado
  Y baja de posición en el orden por urgencia

Escenario 3: el spinner de working sigue al estado real  [criterio 3]
  Dado un agente que pasa a `working`
  Entonces su fila muestra spinner mientras lo está
  Y lo pierde en menos de 500 ms cuando termina

Escenario 4: upsertAgent ya no es fuente de estado  [criterio 4]
  Dado un agente conocido con `status = working`
  Cuando llega un `pane.updated` de ese pane con `agent_status = blocked`
  Entonces el `status` del agente en el Store sigue siendo `working`
  Y sus campos estructurales (`workspace_id`, `tab_id`, `focused`) SÍ se actualizan
  Y no se dispara ninguna transición

Escenario 5: una ráfaga produce UNA sola petición  [criterio 5]
  Dado un contador sobre la costura de resync, sin red
  Cuando llegan 10 eventos dentro de la ventana de debounce
  Entonces la costura registra exactamente 1 petición de snapshot

Escenario 6: un resync en vuelo no se solapa  [criterio 6]
  Dado un resync en vuelo sobre la costura inyectada
  Cuando llega un segundo aviso antes de que termine
  Entonces no hay dos resyncs simultáneos
  Y el segundo se atiende una vez terminado el primero (se encola, no se pierde)

Escenario 7: un snapshot idéntico no repinta  [la guarda de no-op]
  Dado un Store ya poblado por un snapshot
  Cuando se aplica un snapshot cuyos campos de huella son idénticos
    (aunque `revision` haya cambiado en todas las filas)
  Entonces no se dispara `onChanged` ninguna vez

Escenario 8: la guarda de no-op no traga un cambio real  [el contrapunto del 7]
  Dado un Store ya poblado por un snapshot
  Cuando se aplica un snapshot en el que UN solo agente cambió de `agent_status`
  Entonces `onChanged` se dispara exactamente una vez
  Y el Store refleja el estado nuevo

Escenario 9: parada limpia con el trabajador dormido
  Dado un EventsClient arrancado y su trabajador de resync esperando en el semáforo
  Cuando se llama a `stop()`
  Entonces el trabajador despierta, ve `stopping` y termina
  Y `stop()` retorna sin colgarse
```

## Obligaciones que bajan del ledger a este diseño

Cada una declara **qué rastro deja y dónde se busca** (lección #92: una obligación escrita como
intención es incomprobable), y **el nombre del test** que la satisface.

1. **Gate de ejecución real con el entorno saneado** (ledger #93 — el gate de #81 pasó en verde
   sobre una app que panicaba). **Rastro:** el reporte de QA pega el **comando exacto** con
   `env -u HERDR_SOCKET_PATH` y su **exit code**. Sin el comando pegado, el gate no cuenta.
2. **Cronómetro en los tres sentidos, no solo el feliz** (criterios 1-3; en #81 el glifo se quedaba
   pegado justo en el sentido de vuelta). **Rastro:** tabla en el reporte de QA con una fila por
   sentido — `→blocked`, `→idle`, `working→fin` — y el tiempo medido en cada una.
3. **Sesión larga** (los dos fallos medidos en #81 fueron congelación y desincronización, ninguno
   visible en 10 s). **Rastro:** el reporte declara la duración observada y el número de cambios de
   estado provocados; mínimo 5 minutos y 10 cambios.
4. **Cada test nuevo declara el sabotaje que lo vio en rojo** (ledger #92, generalizado a la clase:
   el test que no tiene fila es el que no se probó). **Rastro:** QA lista cada test nuevo del diff
   con su sabotaje y el mensaje del fallo.
5. **El auditor se lanza con QA terminado y commiteado, nunca en paralelo** (ledger #95, que ya se
   incumplió una vez tras escribirse). **Rastro:** el PM pega el SHA del commit sobre el que audita.
6. **Cruzar cada camino nuevo contra su test** (ledger #78: `zig build test` en verde no es
   evidencia de un handler sin bugs si ningún test lo ejercita). **Rastro:** el PM cruza la lista de
   funciones nuevas/modificadas del diff contra los nombres de test de abajo.

**Nombres de test que satisfacen cada escenario** (lección #92: un artefacto sin nombre en el
diseño se comprueba solo si alguien lo recuerda; con nombre, se comprueba con un `grep`):

| Escenario | Test | Archivo |
|---|---|---|
| 4 | `upsertAgent: un pane.updated NO cambia el status del agente` | `src/model/Store.zig` |
| 4 | `upsertAgent: un pane.updated SÍ actualiza workspace/tab/focused` | `src/model/Store.zig` |
| 5 | `requestResync: una ráfaga de N avisos produce una sola petición` | `src/herdr/Events.zig` |
| 6 | `requestResync: un aviso durante un resync en vuelo se encola, no se solapa` | `src/herdr/Events.zig` |
| 7 | `applySnapshot: un snapshot con la misma huella no dispara onChanged` | `src/model/Store.zig` |
| 7 | `applySnapshot: revision distinta no cuenta como cambio` | `src/model/Store.zig` |
| 8 | `applySnapshot: un cambio de agent_status SÍ dispara onChanged` | `src/model/Store.zig` |
| 8 | `applySnapshot: un cambio de título/label SÍ dispara onChanged` | `src/model/Store.zig` |
| 9 | `EventsClient.stop(): despierta al trabajador de resync dormido` | `src/herdr/Events.zig` |
| debounce | `debounce: dos eventos seguidos programan un solo timeout` | `src/ui/herdr_link.zig` |

Escenarios 1, 2, 3 son de **ventana real**: no tienen test unitario y los ejecuta el PM en la sesión
Wayland con el guion de QA. Su rastro son las obligaciones 1-3.

## Riesgos y preguntas abiertas

- **La huella enumera campos a mano.** Si mañana el sidebar pinta un campo nuevo y nadie lo añade a
  la huella, el sidebar se queda rancio y **el modo de fallo es silencioso**. Mitigación: la huella
  vive pegada a `applySnapshot` con un comentario que nombra `buildRows` como su contraparte, y los
  escenarios 7/8 la fijan en los dos sentidos. Se declara como riesgo vivo, no como resuelto.
- **`state_change_seq` entra en la huella pero no se ha verificado contra el servidor real que suba
  en todos los cambios de estado.** Está en el esquema (`types.zig:85`) y su nombre lo promete; no
  se ha medido. No es crítico: `agent_status` también entra, así que un `state_change_seq` que no
  suba no puede ocultar un cambio de estado. Hueco declarado.
- **p95 de 105 ms medido con 14 panes.** No se sabe cómo escala a una sesión de 50. Si escalara mal,
  el margen de 2× sobre los 500 ms se come; se vuelve a medir cuando exista una sesión así.
- **El desempate por `revision` deja de ser inmediato** — ver arriba, va a `CONCERNS.md`.
