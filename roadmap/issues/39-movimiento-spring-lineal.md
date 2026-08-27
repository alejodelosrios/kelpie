title: Movimiento: spring para lo que el usuario provoca, lineal para el spinner de "trabajando"
labels: type:feat,area:ui
milestone: M4 — Acabado visual
---
## Contexto
herdrm mueve poco y con muelles: `spring(response: 0.28, dampingFraction: 0.55)` para
selecciones/aparición y `spring(0.25, 0.85)` para transiciones; el spinner de trabajo es
`linear(0.9 s)`. Depende de #36.

## Alcance
Entra: `adw.SpringAnimation` para resaltar la fila seleccionada, abrir/cerrar la búsqueda y
mostrar/ocultar la cabecera de dispositivo, con parámetros convertidos desde herdrm
(`stiffness = mass·(2π/response)²`, `damping_ratio` = dampingFraction; anotar los valores en el
issue); `adw.TimedAnimation` lineal de 900 ms en bucle para el spinner de 12 px; respeto de
`gtk-enable-animations` (si está apagado, sin animación).
No entra: transiciones de página, animaciones en el terminal.

## Criterios de aceptación
- [ ] Seleccionar una fila anima el lavado con el spring (0.28/0.55 convertido) y termina en < 400 ms.
- [ ] El spinner gira a velocidad constante (lineal), 1 vuelta cada 0.9 s, y se detiene al dejar de "trabajar".
- [ ] `gsettings set org.gnome.desktop.interface enable-animations false` desactiva todo movimiento (restaurar después).
- [ ] No hay animación alguna en estado idle (nada se mueve si nada pasa).

## Referencias
- context7: libadwaita `AdwSpringAnimation`, `AdwSpringParams`, `AdwTimedAnimation`.

## Skills
`context7`, `omarchy-app`.
