---
name: Bug
about: Algo falla o se cae
labels: type:fix
---

## Qué pasó

## Cómo reproducirlo

1.

## Si se cayó (SIGSEGV/SIGABRT)

Pega la salida de `coredumpctl list kelpie | tail -3` y usa la skill `diagnose-crash` para
obtener el backtrace simbolizado. Adjunta el backtrace, no el core.

## Entorno

- `kelpie --version`:
- `cat /usr/share/omarchy/version`:
- `herdr --version`:
- `zig version` (si compilaste):
