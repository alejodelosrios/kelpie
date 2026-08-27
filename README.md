# kelpie

Consola nativa de **Omarchy** para [herdr](https://github.com/herdrdev/herdr): el perro pastor de tu
manada de agentes. Equivalente en propósito a [herdrm](https://github.com/missuo/herdrm) (macOS),
construida con Zig 0.16 + libghostty-vt + GTK4/libadwaita e integrada de raíz con Omarchy: sigue el
tema del sistema en vivo, notifica por el canal de Omarchy con click-para-enfocar y aporta un widget
a la barra.

Lo que Hyprland no te da y kelpie sí:

1. Sidebar multi-dispositivo con agentes ordenados por urgencia: `bloqueado → hecho → trabajando → idle`.
2. Notificación en el instante en que un agente se traba, clickeable, que enfoca ese agente.
3. Búsqueda global difusa de cualquier agente en cualquier máquina (`Ctrl+K`).
4. Terminal real con attach al PTY del agente.

El mosaico de panes no es el valor de kelpie: eso ya lo hace Hyprland.

## Estado

Bootstrap (M0). Roadmap en [issues y milestones](../../milestones); decisiones en `docs/adr/`.

## Compilar

```sh
zig build            # zig-out/bin/kelpie
zig build test
zig fmt --check build.zig build.zig.zon src
```

Requiere Zig 0.16 (`pacman -S zig`). El CI corre en un contenedor Arch: lo que compila ahí es lo que
instala un usuario de Omarchy.

## Trabajar en el repo

- Skills del proyecto en `.claude/skills/`: `zig-libghostty` (APIs verificadas, contrato de filas
  sucias) y `omarchy-app` (rutas, notificaciones, barra, plantillas).
- Commits convencionales que explican el *por qué*, p. ej.
  `fix(terminal): only ⌘D hands the keyboard to the split shell, not every rebuild`.
- Cada decisión irreversible lleva un ADR numerado en `docs/adr/`.

## Licencia

MIT. libghostty-vt es MIT; herdr es Apache-2.0 y solo se le habla por su socket.
