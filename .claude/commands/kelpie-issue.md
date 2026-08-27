---
description: Crea o corrige issues de kelpie con el formato que el enjambre exige (Contexto/Alcance/Criterios/Referencias/Skills) y sus labels.
---

# /kelpie-issue — helper de issues

`$ARGUMENTS`: descripción libre de lo que hay que crear, o `#N` para auditar/arreglar uno existente.

Un issue mal enriquecido rompe la delegación de aprobación del fleet: el hijo diseña en abierto y
tú acabas aprobando todo a mano. El formato **no es burocracia, es la precondición del paralelismo**.

## Formato obligatorio (calcado de `roadmap/issues/*.md`)

```markdown
## Contexto
Por qué existe, qué lo precede. "Depende de #N" si aplica — el fleet lee esa línea para derivar olas.

## Alcance
Entra: … (archivos y comportamiento concretos)
No entra: … (lo que explícitamente se deja fuera)

## Criterios de aceptación
- [ ] Binarios y medibles. Un número, un archivo, un comando que pasa. Nada de "funciona bien".

## Referencias
`archivo:línea` de la fuente pinneada, ADR, o context7. Sin referencias el builder alucina.

## Skills
`zig-libghostty`, `omarchy-app`, `context7` — las que apliquen.
```

## Labels (ya existen en el repo)

- **area**: `vt` `render` `font` `pty` `rpc` `ssh` `ui` `omarchy` `pkg` → el area decide el builder:
  core (`vt,render,font,pty,rpc,ssh`) vs ui (`ui,omarchy,pkg`).
- **type**: `spike` `feat` `fix` `docs` `chore`
- **risk:high** — puede tumbar el plan; desriesgar antes.
- **later** — fuera del camino crítico de 1.0.

Un `type:spike` **debe** tener criterio binario de éxito y su fila en la escalera de fallback del
ADR-0001. Si falla, se para y se informa; no se improvisa el workaround en el mismo PR.

## Qué haces

1. **Crear**: redacta el issue completo, elige labels y milestone, enséñalo, **espera aprobación**,
   y créalo con `gh issue create`. No inventes referencias: si no puedes citar `archivo:línea`,
   déjalo como pregunta abierta explícita — **un hueco declarado es seguro, una suposición con
   forma de dato no lo es**.
2. **Auditar `#N`**: léelo, señala qué falta contra el formato y ofrece el cuerpo corregido.
   Si el issue no tiene criterios binarios ni referencias, dilo claro: **no está listo para el
   fleet**, y lo que necesita es `/kelpie-research`, no un builder.
3. **Kanban**: `gh issue edit` para labels/milestone; el estado real es el issue abierto/cerrado y
   su PR. No inventes un tablero paralelo.
