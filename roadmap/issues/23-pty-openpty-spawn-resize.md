title: PTY: openpty, spawn del proceso hijo, TIOCSWINSZ y hilo lector que alimenta el terminal
labels: type:feat,area:pty
milestone: M2 — Terminal embebido
---
## Contexto
Sin PTY el widget solo muestra bytes sintéticos. Aquí `TerminalView` corre un proceso real
(`bash`, y en #27 el attach de herdr). Depende de #21.

## Alcance
Entra: `src/terminal/Pty.zig`: `openpty(3)` (libc, `-lutil` si aplica), `fork` + `setsid` +
`ioctl(TIOCSCTTY)` + `dup2` de los tres fds + `execvpe` del comando con `TERM=xterm-256color`,
`COLORTERM=truecolor` y el entorno del usuario; `ioctl(TIOCSWINSZ)` en cada cambio de rejilla;
hilo lector `read()` → `TerminalView.feed` (bajo lock) → despertar UI; escritura hacia el PTY desde
la UI (#24); `waitpid` para reaping y señal "proceso terminado" hacia la vista; cierre limpio al
destruir la vista (SIGHUP al grupo, cerrar fds, join del hilo).
No entra: `posix_spawn`, terminfo propio (`xterm-ghostty`), scrollback persistente.

## Criterios de aceptación
- [ ] `kelpie --demo-shell` abre una ventana con `bash` interactivo: `ls --color`, `vim` y `htop` funcionan y salen limpiamente.
- [ ] Tras redimensionar la ventana, `stty size` dentro del shell coincide con filas×cols visibles.
- [ ] `Ctrl+C` interrumpe `sleep 100`; `exit` cierra la vista sin dejar zombis (`ps` no muestra `<defunct>`).
- [ ] `cat` de un archivo de 50 MB no bloquea la UI (el lector lee en trozos y la UI sigue respondiendo).
- [ ] Cerrar la ventana con un `vim` abierto termina el proceso y su grupo en < 1 s.
- [ ] Test: spawn de `printf 'hola\n'`, lectura hasta EOF, exit status 0.

## Referencias
- Ghostty `src/pty.zig` y `src/termio/` (MIT) del commit pinneado: openpty, resize, reaping.
- `man 3 openpty`, `man 4 tty_ioctl` (TIOCSWINSZ, TIOCSCTTY).

## Skills
`zig-libghostty`.
