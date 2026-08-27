title: PKGBUILD reproducible sin red en `build()`: `zig build --fetch` en `prepare()`, `--system` y `-Dcpu=baseline`
labels: type:feat,area:pkg
milestone: M6 — Distribución
---
## Contexto
Los builds de AUR/chroot no tienen red en `build()`. El patrón lo marca el PKGBUILD oficial de
`ghostty` en Arch: cache global de zig llenada en `prepare()`, `--system` en `build()`. Depende de #40, #44.

## Alcance
Entra: `packaging/PKGBUILD` (`pkgname=kelpie`, `depends=(gtk4 libadwaita pango glib2 openssh)`,
`makedepends=(zig git)`, `optdepends=("herdr: …")`); `prepare()`: `ZIG_GLOBAL_CACHE_DIR="$srcdir/zig-global-cache" zig build --fetch`;
`build()`: `DESTDIR=build zig build --prefix /usr --system "$srcdir/zig-global-cache/p" -Doptimize=ReleaseFast -Dcpu=baseline`;
`package()`: copia de `build/usr`, `LICENSE` a `/usr/share/licenses/kelpie/`, assets a
`/usr/share/kelpie/{themed,plugin,hooks}`; `.SRCINFO`; `namcap` limpio; build en chroot limpio
(`extra-x86_64-build` de devtools) verde; `-Dcpu=baseline` obligatorio (binario distribuible).
No entra: `kelpie-git`, flatpak (#52).

## Criterios de aceptación
- [ ] `makepkg -s` local y `extra-x86_64-build` (chroot) producen el paquete sin red en `build()` (probar con `unshare -n` en build).
- [ ] `pacman -U kelpie-*.pkg.tar.zst && kelpie --version && kelpie setup --dry-run` funcionan.
- [ ] `namcap PKGBUILD kelpie-*.pkg.tar.zst` sin errores (warnings justificados en comentario).
- [ ] El `.desktop`, icono, licencia y assets están en las rutas de #44/#43.

## Referencias
- PKGBUILD de `ghostty` en Arch (`gitlab.archlinux.org/archlinux/packaging/packages/ghostty`): `prepare()` líneas 35-37, `build()` 40-48.
- `zig build --help` (0.16): `--fetch`, `--system`, `--prefix`, `--release`.

## Skills
`zig-libghostty`.
