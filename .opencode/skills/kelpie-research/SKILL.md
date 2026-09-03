---
name: kelpie-research
description: Investiga (bug de campo, feature nueva, incógnita técnica) y produce un expediente + issues enjambre-listos que el fleet pueda consumir sin diseñar en abierto. Úsala cuando el usuario pida investigar un bug, una feature nueva fuera del roadmap, o una incógnita técnica de kelpie antes de crear issues.
---

# kelpie-research — investigación → issues enjambre-listos

La entrada del usuario: la pregunta, el bug o la feature.

Los issues del roadmap ya vienen enriquecidos. Esta skill es para **todo lo que nazca fuera de
ese roadmap**: un bug, un spike que falló y obliga a replantear, o una feature nueva. Su producto no
es una opinión: son **issues que el fleet puede consumir**.

## Regla dura: verificar antes de enriquecer

**Ninguna afirmación entra al expediente sin evidencia ejecutada.** Nada de "probablemente GTK
hace…". Se lee el código pinneado, se corre el comando, se cita `archivo:línea`. En este stack —
Zig 0.16 nuevo, `ghostty-vt` explícitamente inestable, bindings generados — el recuerdo es el
enemigo número uno.

## Rutea por modo

### Modo bug — el loop rojo antes de la hipótesis
1. **Reproduce primero.** Un test o un comando que falla **hoy**. Sin rojo reproducible no hay
   hipótesis que valga: estarías arreglando una historia.
2. Con el rojo en mano, busca **causa raíz**, no el síntoma: `grep` todos los llamadores de la
   función sospechosa. El arreglo perezoso correcto es una guarda en la función compartida, no una
   en cada llamador.
3. El issue lleva el comando de reproducción y el rojo esperado en verde.

### Modo incógnita técnica → spike
Si la respuesta no se puede leer (hay que medirla: fps, latencia, si un binding existe), no
investigues en abierto: **redacta un spike** con criterio binario y su fila en la escalera de
fallback del ADR-0001. Medir es más barato que discutir.

### Modo feature
Lee el código que tocaría, decide si cabe en la arquitectura del ADR-0001, y **corta en tracer
bullets**: rebanadas verticales que se pueden mergear solas y dejan la app usable. Nada de "fase 1
que no hace nada visible".

## Lente YAGNI antes de cerrar

Ordena por valor real y **corta aquí**: el corte en el enriquecimiento es gratis, después cuesta
builders, QA y auditor. Recuerda el norte del README — el mosaico de panes no es el valor de kelpie.
Lo que no está en el camino crítico de 1.0 nace con label `later`.

## Producto

1. **Expediente** en `roadmap/research/<slug>.md`: qué se preguntó, qué se ejecutó (con salida real),
   qué se concluyó, qué quedó como pregunta abierta.
2. **Issues propuestos** con el formato de la skill `kelpie-issue`, cada criterio binario y cada
   referencia citada, más el bloque que el fleet necesita: **dominio** (labels `area:*`) y
   **depende de #N**.
3. **DETENTE**: el humano aprueba el expediente y los issues antes de crearlos.

Si algo quedó sin verificar, va como pregunta abierta en el issue — **nunca como suposición
redactada con forma de hecho**. Eso es lo que hace que el fleet derive olas sobre dominios
inventados.
