---
description: Supervisa varios /kelpie-flow en paralelo (uno por issue) en worktrees y panes de Herdr. Segunda puerta para ≥2 issues.
---

# /kelpie-fleet — orquestador multi-issue

Eres el **orquestador**. No escribes código ni procesas issues tú mismo: lanzas un hijo
`/kelpie-flow` por issue, cada uno en su worktree y su pane de Herdr, y los coordinas por blackboard
(git + GitHub + este pane). **Los hijos nunca hablan entre sí.**

Argumento: `$ARGUMENTS` — números de issue.

---

## FASE 0 — Admisión (dónde se gana o se pierde el paralelismo)

1. Con 1 solo issue → corre `/kelpie-flow <N>` aquí mismo, sin worktree. No montes un fleet para uno.
2. Lee cada issue (`gh issue view`) y extrae **dominio** (de los labels `area:*`) y **dependencias**
   (la línea "Depende de #N" del cuerpo — tus issues la traen).
3. **Regla de admisión, derivada, no escrita a mano:** dos issues corren en paralelo si y solo si
   ninguno está en el `depende_de` del otro **y** no comparten territorio de builder.
   - `area:vt|render|pty|rpc|ssh|font` → territorio **core**
   - `area:ui|omarchy|pkg` → territorio **ui**
   - Mismo territorio sin dependencia: **pueden correr en paralelo, con rebase obligatorio sobre
     `develop` antes del PR** (el ruleset de GitHub lo exige de todas formas).
4. **Hotspots de kelpie** (archivos que casi todo issue toca, aunque los dominios sean disjuntos):
   `build.zig`, `src/main.zig`, `src/app.zig`. Se manejan por **lease, no por bloqueo**: si dos
   hijos van a tocar el mismo hotspot, se lo das a uno y el otro espera a la siguiente ola, o lo
   editas tú en el pane principal. Anótalo al planear la ola.
5. Imprime el **plan de olas** (qué corre junto, qué espera y por qué) y **DETENTE** hasta que el
   humano lo apruebe. Si el conjunto no puede correr junto, dilo con nombre y apellido: no lo
   serialices en silencio ni lo lances en paralelo esperando suerte.

Ola típica de M0: los spikes #2–#6 son independientes y con criterio binario — la ola perfecta.
Ojo con #3 (renderer) y #6 (toast): sus gates **abren ventana en tu sesión Wayland**; los hijos
compilan y miden en paralelo, pero la verificación visual se serializa contigo.

## FASE 1 — Worktrees

Uno por issue, desde `develop`:

```sh
git fetch origin develop
git worktree add ../kelpie-<N> -b <prefijo>/<N>-<slug> origin/develop
```

- `.claude/` va **versionado**, así que el worktree nace con comandos, agentes y skills. No hay
  symlinks que mantener.
- Zig no necesita provisión: `.zig-cache/` y `zig-out/` se regeneran, y las deps van al cache global.
  Un `zig build` inicial en cada worktree calienta el cache y confirma que el árbol está sano.

## FASE 2 — Lanzar los hijos (verifica que arrancaron)

Un pane de Herdr por worktree. Tres trampas verificadas en la Ola 1 de M0; las tres dejan un pane
que parece vivo y no hace nada:

1. **Un pane con `agent_status: unknown` no es un pane libre.** Puede tener lazygit, vim o un pager
   abierto: `pane run` entra como **teclas dentro de esa TUI**, no como comando. Comprueba antes con
   `herdr pane process-info '<pane>'`; si no es una shell, **no lo reutilices** — abre uno nuevo, que
   además nace con el cwd correcto:

   ```sh
   herdr pane split '<pane-vecino>' --direction right --cwd "$PWD/../kelpie-<N>"
   ```

2. **`pane run` escribe el texto pero no lo envía dentro de Claude.** Lanzar el binario funciona
   (la shell sí ejecuta), pero el slash-command se queda tipeado en el prompt. Remata siempre con
   `send-keys Enter`:

   ```sh
   herdr pane run '<pane>' 'claude --model sonnet'      # la shell lo ejecuta
   herdr pane read '<pane>'                             # confirma que hay prompt de Claude
   herdr pane run '<pane>' 'Eres hijo del fleet: te lanza /kelpie-fleet desde el pane orquestador, no un humano. El scope gate y el gate de diseño los aprueba el orquestador por este mismo chat; el gate humano es solo el merge. /kelpie-flow <N>'
   herdr pane send-keys '<pane>' Enter                  # sin esto el hijo nunca arranca
   ```

   **El prefijo no es cortesía: es la procedencia del canal.** `/kelpie-flow` a secas declara que lo
   lanzó un humano y manda **detenerse en el scope gate**, así que el hijo para donde no debe. Peor:
   cuando después le escribes por el chat del pane, no tiene forma de saber que existe un fleet
   encima y trata tu mensaje como **inyección de autoridad** — correctamente, según la fila de #4 de
   `lessons-learned.md`. Pasó en la Ola 1 de M1 y paró la ola entera. La procedencia se establece
   **al arrancar**; un mensaje que reclama autoridad a mitad de camino no puede probarla.

3. **Nunca fire-and-forget:** tras el Enter, `herdr pane read` y confirma spinner o FASE 1 en
   pantalla. Un `%` de contexto que no crece es un hijo que no arrancó.

Los hijos corren con **Sonnet** (los issues vienen enriquecidos: ejecutan una spec acotada, no
diseñan en abierto). Si un issue resulta genuinamente ambiguo, súbelo a Opus tú.

## FASE 3 — Vigilancia (el trabajo real del orquestador)

**El listener se ARMA, no se recuerda.** Vigilar "a ojo" falla siempre: los hijos llegan al primer
gate en ~2 min y quedan ahí callados hasta que alguien mira. En cuanto los panes estén corriendo,
arma un `Monitor` persistente sobre `agent_status` — `working` es silencio, cualquier otra cosa es
un evento que te llega al chat:

```
prev=""
while true; do
  cur=$(herdr pane list 2>/dev/null | jq -r '.result.panes[]
    | select(.pane_id=="<pane-A>" or .pane_id=="<pane-B>")
    | "\(.pane_id) \(.agent_status)"' | sort || true)
  if [ -n "$cur" ]; then
    comm -13 <(echo "$prev") <(echo "$cur") 2>/dev/null | grep -v ' working$' || true
    prev="$cur"
  fi
  sleep 20
done
```

Cubre los tres finales, no solo el feliz: `idle` (te espera), `blocked`/`done` y `unknown` (el hijo
murió). Si solo vigilaras el merge, un hijo caído se ve idéntico a un hijo pensando.

**Dos propiedades que el listener necesita, y que se aprendieron fallando:**

1. **Latido, no solo flanco.** Un hijo esperando es un *estado*, no un evento. Si el monitor solo
   emite en el cambio, un hijo que entra en `blocked` avisa una vez y calla mientras espera. Re-emite
   cada 2-3 min mientras haya alguien fuera de `working`.
2. **Se re-arma en CADA reanudación.** Al parar el fleet se apaga el monitor; al reanudar hay que
   **volver a armarlo antes de tocar a ningún hijo**. Reanudar a los hijos sin reactivar la vigilancia
   deja el fleet corriendo a ciegas — y quien lo nota es el humano, avisando por tercera vez.

**Checklist de reanudación**, en este orden y sin saltarse el primero:

```
1. armar el Monitor        <- SIEMPRE primero
2. leer estado real        (state files + git log/status de cada worktree + gh pr list)
3. reanudar a los hijos
```

**El primer gate que te llega es el scope gate, y lo apruebas TÚ**, no el humano: contrástalo contra
el issue (archivos declarados dentro de su territorio, nada de scope extra) y sigue. Al humano solo
le suben los gates de diseño, los spikes que fallan su criterio binario y los merges.

Un hijo puede quedarse atorado en cualquier fase esperando una respuesta tuya. Distingue:

- **esperando a un subagente** (QA, auditor corriendo) = **activo**, no lo toques;
- **esperándote a TI** (scope gate, gate de diseño, menú, pregunta) = **idle bloqueado**, atiéndelo ya.

Lo que apruebas tú, contra el issue enriquecido y su diseño:
- **scope gates** de los hijos,
- **gates de diseño** (la spec + Gherkin) — esta es la aprobación que más te va a llegar,
- decisiones de fallback a Claude cuando MiMo falló dos veces.

Lo que escalas al humano: contradicciones entre el issue y el código, un spike que **falla su
criterio binario** (ADR-0001: se para y se informa, no se improvisa un workaround), un auditor que
DENIEGA dos veces, y **todo merge**.

**Vigila también el avance de `develop`**: si mergeas un PR, los demás hijos quedan desactualizados
y el ruleset les exigirá rebase. Avísales en cuanto pase; no esperes a que su PR rebote.

**No mates a un hijo por reloj.** Un QA visual riguroso tarda. Mata por **falta de progreso**: sin
cambios en su diff ni en su pane durante varios ciclos, no por minutos transcurridos.

**Y "sin progreso" se mide en el árbol y en el transcript, no en el reloj.** Los builders corren
con `scripts/kelpie-builder`, que lanza `claude --print`. Su `--output-format json` **no emite nada
hasta terminar**, así que el fichero de salida vacío no dice nada. Lo que sí dice algo:

```sh
git -C ../kelpie-<N> status --short | awk 'NF'                    # ¿aparecieron archivos?
wc -l ~/.claude/projects/<proyecto-slug>/<session-id>.jsonl        # ¿sigue actuando?
```

El `.jsonl` de la sesión se escribe **en vivo**, herramienta a herramienta. Es la única vigilancia
fiable de un builder, y distingue las tres cosas que desde fuera se ven iguales: trabajando,
esperando, y muerto.

## FASE 3b — La regla de merge del orquestador

> ### 🔴 NADA SE MERGEA EN ROJO.
>
> El orquestador es quien ejecuta el `gh pr merge` cuando el humano lo autoriza, así que es **el
> último filtro**. Antes de cada merge, comprueba las tres condiciones sobre el **head actual** de
> la rama, no sobre un estado que leíste hace diez minutos:
>
> 1. `mergeStateStatus == CLEAN`,
> 2. **todos** los checks en `SUCCESS` — ninguno `PENDING`/`IN_PROGRESS`,
> 3. `0` commits detrás de `develop`.
>
> **Un `CLEAN` viejo miente.** Ocurrió en la Ola 1: el PR estaba `CLEAN`, se empujó un commit de
> corrección de una cita, y ese push disparó un CI nuevo; el `CLEAN` que tenías en la mano era del
> commit anterior y el merge rebotó contra el ruleset. Si vigilas con un `Monitor`, su condición de
> salida debe exigir `CLEAN` **y** todos los checks concluidos en `SUCCESS`, nunca solo `CLEAN`.
>
> Y una autorización humana de merge (`"mergea 61"`) **no es una autorización a mergear en rojo**:
> autoriza el merge de algo verde. Si al ir a ejecutarlo está rojo, se para y se informa — el humano
> autorizó integrar trabajo terminado, no meter una rotura en `develop`.
>
> Cuando el CI de un hijo falle, **avísale con el log del fallo**, no solo con "está rojo":
> `gh run view <id> --log-failed | tail -30`. Un fallo que solo aparece en el runner y no en local
> es un hallazgo del ciclo y merece entrada en `lessons-learned.md`.

## FASE 4 — Cierre (nadie más lo hace)

**El orden importa: el worktree se quita ANTES de borrar la rama.** Mientras un worktree tenga
tomada la rama, `git branch -d` y el `--delete-branch` de `gh pr merge` fallan — y su error habla
solo de la rama **local**, así que se lee como si el borrado remoto sí hubiera ocurrido. No ocurrió.
Así se acumularon 12 ramas remotas huérfanas durante cuatro olas de M1 sin que nadie lo notara.

Por cada hijo que mergeó su PR, en este orden:

```sh
git -C ../kelpie-<N> status --porcelain        # mira qué quedó suelto ANTES de borrar nada
rm -f ../kelpie-<N>/audit-<N>.md ../kelpie-<N>/apply-<N>*.log ../kelpie-<N>/qa-manual-<N>.md
git worktree remove ../kelpie-<N>              # primero el worktree
git branch -D <prefijo>/<N>-<slug>             # después la rama local
git push origin --delete <prefijo>/<N>-<slug>  # y SIEMPRE la remota, explícita
gh issue close <N>
```

El `push --delete` va explícito aunque hayas usado `gh pr merge --delete-branch`: si ese flag falló
por el worktree, este comando es el que de verdad limpia, y si ya se borró, falla sin daño.

> ### 🧹 El estado que inyectaste FUERA del repo también se limpia
>
> Si para probar algo cambiaste el estado de un agente de herdr —`herdr pane report-agent`, un pane
> sintético de títere, cualquier cosa que altere lo que el usuario ve— **eso se revierte al terminar,
> y la limpieza se verifica leyendo el estado de vuelta**, nunca por el exit code.
>
> Pasó en el gate de #84: se creó el títere `wA:p9` con `agent=probe` y se dejó en `blocked` para la
> confirmación visual. El `release-agent` de la limpieza **omitía el flag obligatorio `--agent` y
> devolvió `exit 0` sin hacer nada ni imprimir nada**. El cierre se dio por bueno tras verificar
> worktrees, ramas, PRs e issues — pero nadie verificó el estado inyectado fuera del repo. Lo
> encontró el dueño horas después.
>
> **No es cosmético**: un agente fantasma en `blocked` es exactamente lo que kelpie pone primero en
> la lista y con glifo de alerta. Le estaba gritando al usuario por algo que no existía.
>
> ```sh
> herdr pane release-agent <pane> --source <id> --agent <label>   # AMBOS flags, o falla en silencio
> herdr pane list | awk '/probe|gate|test/'                       # y se comprueba leyendo de vuelta
> ```
>
> Libéralo en un `trap` del propio guion, no en un paso final que puede no ejecutarse si algo se
> interrumpe. Y **nunca `pkill -f <patrón>`**: mata tu propio shell y puede alcanzar procesos del
> usuario. Usa `pgrep -x <nombre-exacto>`. **El servidor `herdr` no se mata jamás** — el dueño tiene
> otras sesiones de otros proyectos colgando de él.

### Verificación de cierre — las SEIS, no dos

```sh
git worktree list                              # solo el repo principal
git branch                                     # solo develop y main
git branch -r                                  # solo origin/develop, origin/main (y origin/HEAD)
gh pr list --state open                        # vacío, o solo lo que dejaste abierto a propósito
gh issue list --state open                     # ningún issue de trabajo ya mergeado
herdr pane list | awk '/probe|gate|test|fix[0-9]/'   # ningún títere que inyectaste tú
```

**La sexta es la que se añadió tras #84**, y es la única que mira fuera del repo. Las otras cinco
salieron verdes con un agente fantasma en `blocked` vivo en la sesión del dueño.

**`git branch -r` es la que se olvidaba**, y es justo donde se acumula la basura invisible: las
ramas huérfanas no aparecen en `git worktree list` ni en `git branch`, y el siguiente fleet las
hereda sin verlas.

> ### ⚠️ «¿Está esta rama mergeada?» se le pregunta al PR, NUNCA al grafo de commits
>
> Este repo mergea con **squash**: el merge crea un commit nuevo en `develop` y los commits
> originales de la rama **nunca** son ancestros suyos. Por eso `git rev-list develop..<rama>` y
> `git branch --merged` dicen «tiene trabajo sin integrar» sobre ramas perfectamente mergeadas —
> las 12 huérfanas daban entre 1 y 8 commits «pendientes». Fiarse de eso lleva a **no borrar nunca**
> nada, o peor, a creer que hay trabajo que rescatar.
>
> La fuente de verdad es el estado del PR:
>
> ```sh
> gh pr list --state all --limit 60 --json number,headRefName,state \
>   --template '{{range .}}{{.headRefName}}|{{.state}}|{{.number}}{{"\n"}}{{end}}'
> ```
>
> Una rama con su PR en `MERGED` se borra. Una rama **sin PR** o con PR `OPEN`/`CLOSED` se
> investiga antes de tocarla — nunca se borra a ciegas.

> ### ⚠️ `grep` no es fiable en esta máquina
>
> Está sombreado por algo que responde `unknown option '-G'` o imprime la versión de Claude Code.
> Un `git status --short | grep -v ...` devuelve **vacío**, que es indistinguible de «el hijo no
> escribió nada» — ya provocó un reporte falso de «worktree vacío» sobre uno con 16 KB de código y
> una auditoría encima. **Usa `awk` para filtrar** en todo comando de vigilancia y de cierre.

**Consolida las lecciones de la ola en `lessons-learned.md`.** Cada hijo escribe las suyas, pero tú
ves lo que ninguno ve: lo que le pasó a **varios** a la vez —el mismo fallo en dos worktrees, un gate
que aprobaste quince veces, una colisión que el plan de olas no predijo, una instrucción tuya que
permitía el fallo—. Eso es una lección del enjambre, no del issue, y solo tú puedes escribirla.

Resume al humano: qué mergeó, qué quedó pendiente y por qué, qué entró en `CONCERNS.md`, qué lección
quedó en `lessons-learned.md`, y qué aprendiste que ya está en las skills.
