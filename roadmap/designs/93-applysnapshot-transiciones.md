# Diseño — #93 `Store.applySnapshot` deriva transiciones (`onTransition` deja de ser código muerto)

> Aprobado por: PM OpenCode (fleet `wA:p5`, `gates=scope,diseño`) · 2026-09-03 · rama `fix/93-applysnapshot-transiciones`
>
> El gate humano de este issue es el **merge**. Scope y diseño los aprueba el PM porque el issue
> viene enriquecido (contrato ya aceptado); solo se escala por contradicción issue/código.

## Spec

`applySnapshot` compara el `status` previo de cada agente con el del snapshot entrante y, cuando
difieren en un agente **ya existente**, dispara `fireTransition(observers, agent, from, to)` además
del `fireChanged` que ya hace. Se respeta el corto-circuito por huella: si nada que el sidebar pinta
cambió, no se muta ni se dispara nada (ni `onChanged` ni `onTransition`).

**Archivos que se tocan** (territorio de un solo builder — `core-builder`):

| Builder | Archivo | Qué cambia |
|---|---|---|
| `core-builder` | `src/model/Store.zig` | `applySnapshot` captura `status` previos, deriva transiciones tras mutar, + tests |

**No entra** (del issue):
- Suscribirse a `pane.agent_status_changed` (herdr 0.8.2 no lo emite; eso es de herdr, no de kelpie).
- Cambiar la firma de `ChangeObserver`.
- Tocar `Notify.zig` ni nada de #18 (#18 se retoma desde `d047cc6` cuando esto cierre).
- `build.zig.zon` y el commit pinneado de ghostty. Cero dependencias nuevas.

## Cadena de activación (obligatoria: el cambio cuelga de un observador)

- Quién dispara: `Store.applySnapshot` (camino de producción del sondeo de 150 ms decidido en #86,
  más el resync con debounce por evento).
- Desde qué camino: `session.snapshot` → `applySnapshot` → `fireTransition` → cada
  `ChangeObserver.onTransition` (entre ellos, `Notify.zig` de #18 cuando se retome).
- El único otro llamador de `fireTransition` (`applyEvent` caso `pane_agent_status_changed`,
  `Store.zig:344`) no se suscribe en producción (`Events.zig:69-71`: llega englobado en
  `pane.updated` y herdr 0.8.2 no lo emite nunca) — por eso `onTransition` es hoy código muerto.
- Cómo se comprueba: test unitario en `src/model/Store.zig` (los 4 casos abajo) + `zig build test`;
  el gate de VALOR (transición real visible en notificación) lo corre #18 en su ventana real, no aquí.

## Cómo se implementa (sin rediseñar en el Apply)

1. Tras el guard de huella (`Store.zig:194-199`) y antes de cualquier mutación destructiva, hacer una
   pasada de lectura que capture `prev_status: AgentStatus` por `pane_id` para los agentes existentes
   (p. ej. iterar `self.agents` y guardar `pane_id → status` en un mapa/stack local, o comparar contra
   `snapshot.agents` buscando por `pane_id`). No mutar en esta pasada.
2. Mantener la disciplina existente de `last_fingerprint`: ya se nulifica antes de mutar
   (`Store.zig:201-203`) y solo se confirma al final (`Store.zig:281`). El nuevo código no la toca.
3. Ejecutar la mutación existente sin cambios (agentes/workspaces/tabs + `last_fingerprint = fp`).
4. Tras `fireChanged` (o justo antes/después, pero siempre tras mutación exitosa), por cada
   `info` en `snapshot.agents` cuyo `pane_id` existía en la captura previa y cuyo
   `info.agent_status != prev`, llamar `fireTransition(&self.observers, agent_ptr, prev, info.agent_status)`
   donde `agent_ptr` es el `*const Agent` **ya mutado** (mismo patrón que `Store.zig:344`: se pasa el
   existente tras actualizar). Un `pane_id` sin entrada previa (agente nuevo) **no** dispara.
   Un agente ausente del snapshot (desaparece) **no** dispara.
5. Regla de memoria (ledger #5): no construir literales `Agent` con `try dupe` inline para la captura
   previa — solo se copian `pane_id` (dupe) + `status` (valor), o se comparan sin alocación iterando el
   snapshot contra el mapa vivo. Cada `dupe` lleva su `errdefer`/`free` como el código existente
   (`Store.zig:213-230`). Si la captura previa aloca y falla, salir con error **sin** haber mutado
   (la huella sigue intacta porque aún no se nulificó) — nunca dejar medio estado.
6. La huella ya incluye `agent_status` (`computeFingerprint`, `Store.zig:617-646`), así que un cambio
   de estado nunca es tragado por el corto-circuito: el guard y la transición no pueden contradecirse.
   No añadir campos a la huella.

## Firmas de API que se van a usar

Ninguna escrita de memoria. Cada fila la verificó el PM con `sed -n '<línea>p' <archivo>` (una
invocación por línea).

| API | Fuente (`archivo:línea`) | Verificada |
|---|---|---|
| `pub fn applySnapshot(self: *Store, snapshot: types.SessionSnapshot) !void` | `src/model/Store.zig:176` | ✅ |
| `const fp = computeFingerprint(snapshot);` | `src/model/Store.zig:193` | ✅ |
| `if (self.last_fingerprint) \|last\|` (guard de no-op) | `src/model/Store.zig:194` | ✅ |
| `self.last_fingerprint = fp;` (confirmación tras mutación) | `src/model/Store.zig:281` | ✅ |
| `fireChanged(&self.observers);` (llamada de `applySnapshot`) | `src/model/Store.zig:284` | ✅ |
| `fn fireChanged(observers: *const std.array_list.Managed(ChangeObserver)) void` | `src/model/Store.zig:825` | ✅ |
| `fn fireTransition(observers, agent, from, to) void` | `src/model/Store.zig:831` | ✅ |
| `fireTransition(&self.observers, existing, from_status, data.agent_status);` (patrón a replicar) | `src/model/Store.zig:344` | ✅ |
| `if (self.agents.getPtr(key)) \|existing\|` (lectura previa del mapa) | `src/model/Store.zig:337` | ✅ |
| `if (from_status != data.agent_status)` (condición de transición) | `src/model/Store.zig:343` | ✅ |
| `pub const ChangeObserver = struct` | `src/model/Store.zig:122` | ✅ |
| `pub fn onTransition(self, agent, from, to) void` | `src/model/Store.zig:131` | ✅ |
| `status: types.AgentStatus,` (campo de `Agent`) | `src/model/Store.zig:23` | ✅ |
| `const AgentKey = struct` | `src/model/Store.zig:44` | ✅ |
| `pub fn computeFingerprint(snapshot: types.SessionSnapshot) u64` | `src/model/Store.zig:617` | ✅ |
| `pub const AgentStatus = enum` | `src/herdr/types.zig:9` | ✅ |
| `pub const AgentInfo = struct` | `src/herdr/types.zig:69` | ✅ |
| `agent_status: AgentStatus,` (campo de `AgentInfo`) | `src/herdr/types.zig:71` | ✅ |
| `pub const SessionSnapshot = struct` | `src/herdr/types.zig:119` | ✅ |
| `pane.agent_status_changed` excluido a propósito; el estado llega vía `pane.updated` | `src/herdr/Events.zig:69` | ✅ |
| `fn makeSnapshot(agents, workspaces, tabs) types.SessionSnapshot` (helper de test) | `src/model/Store.zig:945` | ✅ |
| `fn makeAgentInfo(pane_id, status, revision) types.AgentInfo` (helper de test) | `src/model/Store.zig:957` | ✅ |
| `const TestObserver = struct` (helper de test) | `src/model/Store.zig:969` | ✅ |
| `fn onTransitionImpl(ptr, agent, from, to) void` (helper de test) | `src/model/Store.zig:989` | ✅ |

Huecos declarados: ninguno. Todo lo que el Apply necesita está citado arriba. Si el builder no
encuentra algo, lo devuelve como pregunta abierta, no lo inventa.

## Escenarios (Gherkin — uno por criterio del issue)

```gherkin
Escenario 1: un cambio de estado en un agente existente dispara onTransition [criterio 1]
  Dado un Store poblado por un snapshot con p1 en working
  Cuando se aplica un snapshot idéntico salvo p1 en blocked
  Entonces onTransition se dispara exactamente una vez con from=working to=blocked
  Y onChanged también se dispara

Escenario 2: un agente nuevo no es una transición [criterio 2]
  Dado un Store poblado con p1
  Cuando se aplica un snapshot que añade p2 (nuevo pane_id)
  Entonces onChanged se dispara
  Y onTransition NO se dispara ninguna vez

Escenario 3: sin cambios de estado no hay transición y el corto-circuito sobrevive [criterio 3]
  Dado un Store poblado por un snapshot
  Cuando se aplica un snapshot con la misma huella (aunque revision haya cambiado)
  Entonces onTransition NO se dispara
  Y onChanged tampoco se dispara (el guard por huella sigue intacto)

Escenario 4: un agente que desaparece no es una transición [criterio 4]
  Dado un Store poblado con p1 y p2
  Cuando se aplica un snapshot sin p2
  Entonces onTransition NO se dispara
  Y el Store ya no contiene a p2
```

| Escenario | Test (nombre exacto) | Archivo |
|---|---|---|
| 1 | `applySnapshot: un cambio de agent_status dispara onTransition con from/to` | `src/model/Store.zig` |
| 2 | `applySnapshot: un agente nuevo dispara onChanged pero no onTransition` | `src/model/Store.zig` |
| 3 | `applySnapshot: sin cambios de estado no dispara onTransition ni rompe el corto-circuito` | `src/model/Store.zig` |
| 4 | `applySnapshot: un agente que desaparece no dispara onTransition` | `src/model/Store.zig` |

## Obligaciones que bajan del ledger a este diseño

1. **Cada test nuevo declara el sabotaje que lo vio en rojo** (generalizado #92; fila Ola 3 M1 #11:
   un test que pasa con y sin el fix no prueba nada). **Rastro:** el reporte del builder lista cada
   test con su sabotaje; QA los corre en las dos direcciones (con y sin el fix). Nombres en la tabla
   de arriba — se comprueban con `/usr/bin/grep`, nunca con el `grep` sombreado.
2. **Un literal con campo falible no es atómico** (fila #5). **Rastro:** el diff no añade ningún
   literal `Agent{... try dupe ...}`; la captura previa solo copia `pane_id`+`status` con
   `errdefer`/`free`, y el PM lo verifica leyendo el diff completo.
3. **La tabla de citas cubre el 100% de las llamadas del Apply** (filas #7/#13 + cruce de archivos de
   #3). **Rastro:** FASE 5 relee el diff buscando cualquier `adw./gtk./gio./gdk.` o firma del stack no
   citada y la rechaza; `git diff --stat` debe listar exactamente `src/model/Store.zig` (+ este diseño).
4. **Instrumentos de esta máquina:** `grep` sombreado → `/usr/bin/grep` o `awk`; `cmd | tail` miente →
   `cmd >/dev/null 2>&1; echo $?`; `git diff HEAD -- <archivo>`, nunca `git diff <archivo>` a secas;
   tras el Apply, `git stash list` (un `stash` fantasma del builder es indistinguible de "no pasó nada").
5. **El auditor se lanza con QA terminado y commiteado, nunca en paralelo** (fila #7/ledger). **Rastro:**
   el PM pega el SHA del commit auditado.

## Riesgos y preguntas abiertas

- **Doble disparo si herdr vuelve a emitir `pane.agent_status_changed`.** Hoy no lo emite (medido en
  #84), así que no hay doble transición. Si una futura herdr lo emite, un cambio llegaría por evento y
  por snapshot. Mitigación: cuando eso ocurra, el dueño decide cuál es fuente; hoy no se especula.
- **Orden `fireChanged` vs `fireTransition`.** El diseño pide transición tras mutación exitosa junto a
  `fireChanged`; si QA/auditor prefieren antes/después, es detalle interno sin cambio de contrato
  mientras ambos se disparen una vez por snapshot aplicado.
- **Batería del sondeo** (riesgo heredado de #84, en `CONCERNS.md`): 6.6 snapshots/s para siempre. Este
  issue no lo empeora (misma tasa, un bucle más por snapshot del tamaño del nº de agentes).
