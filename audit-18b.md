# Auditoría #18 — veredicto v2 (rework threading, punto explícito)

> Transcripción literal del reporte del auditor delegado (canal 4 → PM), reanudando
> su misma sesión de Opus (`--resume`). El PM no reinterpreta. Proveniencia: task
> `ses_f82bc90e4ffe4f2SL3OHMe5056` (ronda 2), auditor-18 = Claude Opus en pane propio
> por canal 5. Pane hijo cerrado y verificado (cero fantasmas). Artefacto congelado:
> HEAD `b4a6131`, `git show cad931c` = solo `src/omarchy/Notify.zig` 230+/82−.
> El v1 vive en `audit-18.md`; este v2 reaudita el punto que el orquestador reabrió
> (process.run en hilo de UI + comentario falso de `:197`).

## Veredicto de Opus — LITERAL, sin reinterpretar

```
APROBADO

**Artefacto reverificado por mí:** `git rev-parse --short HEAD` → `b4a6131`, `git status --porcelain` vacío. `git show --name-only cad931c` → **solo `src/omarchy/Notify.zig`**, nada más. `zig fmt --check` → 0. `zig build test --summary all > /tmp/aud18c-test.log` → exit **0**, **51/51 pasos, 205/205 tests**, verde a la primera, sin flaky.

## Foco 1 — ningún `process.run` queda en camino de UI ✅

Los **dos** call sites de `std.process.run` viven en hilos detached, y no queda ninguno en la ruta síncrona:

- `sendNotification` (`Notify.zig:158-208`) solo `allocPrint`/`dupe` × 5 + `create(SendThreadArgs)` + `std.Thread.spawn(.{}, sendThread, .{args})` (`:197`) + `thread.detach()` (`:207`). El `run` está en `sendThread:261`.
- `dismiss` (`:326-369`) resuelve el headline bajo el lock, lo dupea, hace `fetchRemove`, suelta el lock, y spawnea (`:362`) + `detach()` (`:368`). El `run` está en `dismissThread:386`.
- `/usr/bin/grep -n "process.run"` sobre el archivo → exactamente `:261` y `:386`. Cero en camino de UI.

**Y verifiqué que el patrón es el del propio repo, no inventado:** `app_shell.zig:464-469` (`std.Thread.spawn(attachThreadFn)` + `detach()`) y `src/herdr/attach.zig:56` (`std.process.spawn(io, …)`) ya hacen exactamente esto desde #19, mergeado. El commit dice «patrón attachThreadFn» y es literalmente cierto.

**`io` desde un hilo ajeno — lo perseguí como posible UB y no lo es.** `init.io` es `std.Io.Threaded` (`/usr/lib/zig/std/start.zig:724,744`). `Threaded` anticipa el hilo forastero por diseño: `threadlocal var current: ?*Thread = null` (`Io/Threaded.zig:893`), `currentId()` cae a `std.Thread.getCurrentId()` si es `null` (`:898-900`), y `checkCancel()` hace `Thread.current orelse return` (`:905`). Un hilo que no es del pool simplemente no es cancelable; no hay `unreachable` en ese camino.

**`gpa` compartido entre UI y N hilos:** `std.process.Init.gpa` está documentado **«Threadsafe.»** (`/usr/lib/zig/std/process.zig:36-39`) — a diferencia de `environ_map`, que dice «Not threadsafe» (`:43`) y que este diff no toca. Sin carrera de allocator.

## Foco 2 — disciplina del mutex ✅

`std.atomic.Mutex` es real y es lo que el diff cree: `enum(u8){unlocked,locked}` con `tryLock` por `cmpxchgStrong .acquire` y `unlock` con `assert(load == .locked)` + store `.release` (`/usr/lib/zig/std/atomic.zig:506-519`). No tiene `lock()` bloqueante, así que `lockMap` (`:91-93`, spin con `spinLoopHint`) es la forma correcta de usarlo.

Los **cuatro** holds del árbol, todos con `defer …unlock()` en el mismo ámbito que el lock y ninguno abarcando algo bloqueante:

| Hold | Qué hay dentro | Veredicto |
|---|---|---|
| `sendThread:235-237` | un `notifs.get` | ✅ el `run` (`:261`) queda **fuera**, después de soltar |
| `sendThread:295-322` | `getOrPut` + frees + asignación | ✅ sin spawn ni wait dentro |
| `dismiss:332-348` | `get` + `dupe` + `fetchRemove` | ✅ el spawn (`:362`) queda **fuera** del bloque |
| `deinit:101-110` | iterar + frees + `notifs.deinit()` | ✅ lock/unlock en el mismo hilo |

Lock y unlock siempre en el mismo hilo (el `assert` de dueño único de `atomic.zig:516` no se puede disparar). Comprobé que los `return` tempranos dentro del bloque `blk:` de `dismiss` (`:336` `orelse return`, `:337-340` `catch … return`) **sí** desenrollan el `defer unlock` de `:333` — Zig corre los defers pendientes del ámbito al retornar; no queda ningún camino que deje el spinlock tomado.

## Foco 3 — lifetimes y el doble-free que me pediste buscar ✅ no existe

Ningún puntero al `Agent` del Store escapa: `sendNotification` dupea **los cinco** (`headline:166`, `key_device:169`, `key_pane:171`, `agent_name_dup:174`, `workspace_id:177`) y `sendThread` trabaja solo con copias vía `buildArgvFromFields` (`:454-527`), que toma slices sueltas y no un `*Agent`. Recorrí las **seis** salidas de `sendThread` contra las cinco asignaciones:

- `:250-257` (buildArgv falla), `:264-271` (run falla), `:280-287` (parse falla), `:298-305` (getOrPut falla) → cada una libera **las cinco**, ni una de más ni de menos.
- Éxito con `found_existing` (`:307-312`) → libera los duplicados `key_device`/`key_pane` (el mapa conserva su clave vieja) + el `headline`/`agent_name` viejos del entry; luego `:314` libera `workspace_id`; `headline`/`agent_name` transfieren.
- Éxito sin `found_existing` → `key_device`/`key_pane` los consume la clave nueva del mapa; `:314` libera `workspace_id`; `headline`/`agent_name` transfieren.
- `args` se destruye siempre por `defer` (`:228`), y `dismissThread` libera siempre `headline` y `args` (`:381-382`).

**`ArgvResult.deinit` (`:425-428`) no puede doble-liberar**: cada elemento del argv es una asignación fresca — `dupe` para literales, glifo, `urgency_str` y **también para el `headline`** (`:513`), más `body`/`exec_target` que son `allocPrint` propios (`:469-480`). El `args.headline` del hilo **no está aliasado** dentro del argv, así que el `defer argv_result.deinit` (`:259`) y la transferencia al mapa (`:320`) tocan memoria distinta. Era el sitio exacto donde un doble-free habría sido invisible al compilador: está limpio.

El camino de fallo de spawn (`:197-206`) libera las cinco a mano + `destroy(args)`; como es un `return;` de éxito dentro de un `!void`, los `errdefer` de `:167-178` **no** disparan — la fila del ledger de #18 sobre este idiom (2026-09-03) se honra otra vez, y tampoco hay doble-free por el otro lado (si falla el `create` de `:183`, sí disparan los cinco `errdefer` y no hay frees manuales).

## Foco 4 — el comentario falso de `:197` ⚠️ desapareció, pero nació otro

El de `:197` **ya no existe**: lo que hay ahí es el `catch` del spawn. Los comentarios de timeout que quedan (`:377-378`) dicen la verdad sin prometer nada.

**Pero `deinit:97-100` afirma una propiedad de seguridad que no se cumple** — ver preocupación 1.

## Foco 5 — la carrera benigna ✅ y 6 — suite verde ✅

Confirmada y efectivamente benigna: entre `:238` (suelta el lock tras leer `replaces_id`) y `:295` (lo retoma) cabe otro hilo o un `dismiss`; el peor resultado es last-writer-wins sobre `entry.id` o una toast que reaparece justo después de un dismiss. Ninguna variante corrompe memoria — todas las claves y valores tienen dueño único en cada rama.

## Resto del contrato

Sin `unreachable`, `@panic` ni `catch unreachable` (grep sobre el archivo → sin coincidencias). `run_result.term.exited` (`:276`, `:396`) sigue protegido por el cortocircuito de `or`. Cero hexadecimales de color; nada reimplementado de `ghostty-vt`; `build.zig`/`build.zig.zon` intactos; cero dependencias nuevas. `/usr/share/omarchy/` solo se lee; nada escribe en `$HOME`; se llama al binario real y no al dispatcher, con `--exec` y no `-A`. Los seis escenarios Gherkin siguen cubiertos exactamente igual que en v1 (el rework no cambió el argv ni la semántica del switch).

## Preocupaciones para `CONCERNS.md`

**1. `Notify.zig:97-100` — comentario falso de la misma especie que el que se ordenó eliminar (la más importante).** Dice que el `tryLock`-con-skip evita el use-after-free porque «si no podemos adquirir el lock, el hilo liberará sus copias y soltará el lock… el timeout de 3 s acota la espera». El razonamiento es al revés: **el hilo no tiene el lock durante `process.run`** (lo suelta en `:238` y no lo retoma hasta `:295`), así que el `tryLock` de `:101` **tendrá éxito justo en la ventana peligrosa** — con un hilo dentro del `run`, `deinit` pasa el guard, hace `notifs.deinit()` y deja `notifs_inited == true` sobre un HashMap destruido; ese hilo llega luego a `getOrPut` (`:298`) sobre memoria liberada. **Hoy es inalcanzable**: `notify.deinit()` no tiene ningún call site en producción — los tres que hay (`:737`, `:811`, `:862`) son tests de este mismo archivo y ninguno spawnea un hilo. Por eso no bloquea. Pero es una trampa puesta para quien cablee el shutdown mañana confiando en el comentario. Arreglo de una línea, sin builder: cambiar el comentario por «`deinit` no es seguro con hilos en vuelo; no hay call site en producción — antes de añadir uno hace falta un contador de hilos vivos o un join». (Aparte, la errata `the3s` en `:100`.)

**2. El rework introduce concurrencia y añade cero tests — choca con una regla vigente del digest.** `lessons-learned.md:83`: «Concurrencia: observador + escenario que **PRODUZCA** el solapamiento». El total de la suite no se movió (205 antes de `cad931c`, 205 después; las 11 declaraciones `^test ` de `Notify.zig` son las mismas de v1). Toda la coreografía nueva —transferencia de propiedad en `sendThread`, el `free(workspace_id)` de `:314`, la rama `found_existing` cruzada con `fetchRemove` desde otro hilo, el camino de fallo de spawn— está verificada solo por lectura (la mía, arriba, camino por camino). La mitad testeable no depende de D-Bus: dos hilos martillando `lockMap` + `getOrPut`/`fetchRemove` sobre la misma clave con `std.testing.allocator` probarían ausencia de doble-free y de fuga bajo solapamiento real. Recomiendo issue de seguimiento, no otra ronda de builder: el código es correcto, lo que falta es la red que lo mantenga correcto. Relacionado: `:59` («invariantes de memoria van a un test que falle en rojo»).

**3. `lockMap` (`:91-93`) gira sin cota ni cesión.** Si un hilo detached muere en panic con el lock tomado, el hilo de UI queda girando al 100 % para siempre — se cambió un freeze acotado de 3 s por uno potencialmente eterno en un escenario menos probable. Los holds son diminutos y ninguno puede fallar salvo el `getOrPut` (que sí puede asignar y crecer el mapa), así que la probabilidad es baja; el coste de mitigarlo (contador de giros + degradar a `std.Thread.yield`) también.

**4. Un hilo del SO por transición, sin techo.** `applySnapshot:305-312` dispara transiciones en bucle: N agentes que transicionan en el mismo snapshot = N `Thread.spawn` + N `fork`/`exec` simultáneos. Acotado por número de agentes (pequeño hoy). Es la mutación de la preocupación 4 de mi v1: ya no bloquea la UI, pero el coste se movió, no desapareció — el gate Wayland del criterio 1 es el sitio para medirlo.

**5. `audit-18.md` en la raíz del repo (fuera de `cad931c`, dentro de la rama que se mergea).** Es el primer `audit-*.md` commiteado en toda la historia (`git log --diff-filter=A -- 'audit-*.md'` → solo `88b4a56`) y no está en `.gitignore`. f71 dice que el veredicto va a `audit-<N>.md` y que el archivo es el contrato, pero no que viaje a `develop`. Decisión de convención del PM: o se adopta a propósito para todos los issues, o se saca del merge.

**Estado de mis cinco preocupaciones de v1:** la #3 (bloqueo del hilo de UI) está **resuelta** por este rework, verificado arriba. Las #1 (headline con forma de flag), #2 (timeout por `fill()`), #4 (`notify` sin `deinit`) y #5 (coste del spawn) siguen vigentes y las cuatro están fielmente transcritas en `CONCERNS.md` por `b4a6131`, junto con la nota `⚠️` en la fila del hilo. Añado que la #1 de v1 sobre `buildArgvFromFields` sin ningún `errdefer` (`:454-527`, 15 asignaciones falibles) sobrevive intacta al rework y ya está en el ledger de producto: sigue siendo solo-OOM, sigue sin bloquear.

— auditor-18 (Claude Opus, claude-opus-5[1m])
```

## Nota del PM (no parte del veredicto)

- Preocupación 1 (comentario falso de `deinit:97-100`, misma especie que la ya rechazada
  una vez): **se corrige antes del merge** en micro-round del builder (comentario veraz +
  errata `the3s`), con re-verificación del PM. Un comentario que promete seguridad falsa
  no viaja a `develop`, tenga o no call site hoy.
- Preocupación 2 (cero tests para la concurrencia nueva): se propone issue de seguimiento
  al orquestador; no otra ronda (el código está verificado camino por camino, lo que falta
  es la red).
- Preocupaciones 3 y 4: van a `CONCERNS.md` con esta ronda.
- Preocupación 5 (convención `audit-*.md`): decisión del PM — **viajan en el merge**
  (`audit-18.md` v1 + este v2). Son la evidencia escrita del gate que el merge exige
  («APROBADO escrito en `audit-18.md`»); sacarlos del merge dejaría el gate sin rastro.
  Queda propuesto como convención a ratificar: todo issue mergea su `audit-<N>.md`.
