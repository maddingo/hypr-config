# Installing Noctalia on Ubuntu 24.04

Noctalia's README does not build on Ubuntu 24.04 "noble" as written. This
documents why, and what `install-noctalia.sh` does about it. Verified end to end on
**2026-08-02** against Noctalia `5.0.0`, at commits `ae6113f02` (TUXEDO OS) and
`7242ed4d4` (stock noble).

Only the `apt` path is affected — the Arch, Fedora, openSUSE and Void dependency
lines in the README are fine.

## Quick start

`install.sh` does this automatically when `noctalia` is not on `PATH`. To run the
build by hand:

```sh
git clone https://github.com/noctalia-dev/noctalia ~/Develop/noctalia
cp install-noctalia.sh ~/Develop/noctalia/
cd ~/Develop/noctalia
./install-noctalia.sh --install
```

The script builds **in place** and refuses to run outside a Noctalia checkout, so
it has to be copied into one. That is also why `install.sh` clones `$NOCTALIA_SRC`
(default `~/Develop/noctalia`, reused if present) and copies the script in before
running it with `--install`, putting the binary in `~/.local/bin`.

```sh
./install-noctalia.sh                  # apt deps, configure, build (release)
./install-noctalia.sh --no-apt         # skip the only root step
./install-noctalia.sh --install        # also `just install` into --prefix
./install-noctalia.sh --mode debug     # debug instead of release
./install-noctalia.sh --prefix /usr/local
./install-noctalia.sh --no-tuxedo-repo # never add an apt source
```

Expect a long build (700 targets). The `apt` step is the only one needing root;
the script prints the exact `apt-get install` line before running it, and
`--no-apt` skips it if you would rather run it yourself.

## What breaks, and why

Six separate things, each hidden behind the previous — they can only be found by
hitting them in sequence.

| # | Break | Root cause | Fix |
|---|---|---|---|
| 1 | `just configure release` → `Non-default parameter 'args' follows default parameter` at `justfile:48` | apt ships just `1.21.0`; variadic-after-default needs just **1.40.0** (casey/just#2660). just parses the whole file before dispatch, so *every* recipe dies and the error misleadingly names `test` | upstream just in `~/.local/bin` |
| 2 | `stb/stb_image_resize2.h not found` at `meson.build:192` | `libstb-dev` is a 2023-01-29 snapshot; ships `stb_image_resize.h` (v1, different API) and `stb_image_write.h`, not resize2 | vendor the single header, add to `CPPFLAGS` |
| 3 | `fatal error: print: No such file or directory` | 10 sources `#include <print>`; libstdc++ got it in **GCC 14**, but `README.md:220` claims GCC 13+ and lists Ubuntu 24.04 as fine. This is a *library* floor — Clang 16 over libstdc++ 13 fails identically | `g++-14` |
| 4 | `lto1: fatal error: bytecode stream ... generated with LTO version 13.1 instead of the expected 14.0`, at the final link | `README.md:222` says `CXX=g++-13 just configure`. Setting only `CXX` leaves Meson to detect C separately and fall back to default gcc. Generated Wayland protocol sources are C, and release builds set `-Db_lto=true` | set **both** `CC` and `CXX` |
| 5 | `Dependency "wireplumber-0.5" not found, tried pkgconfig and cmake` at `meson.build:91` | noble ships WirePlumber **0.4.17** only. `meson.build:91` requires 0.5 outright, with no fallback and no `meson_options.txt` toggle | `libwireplumber-0.5-dev` from TUXEDO's pinned `ubuntu-plasma` archive |
| 6 | `error: ‘wl_proxy_get_display’ was not declared in this scope`, at `src/wayland/virtual_keyboard_service.cpp:95` | `wl_proxy_get_display` was added in **wayland 1.23.0** (absent in 1.22.0). noble ships 1.22.0 and `meson.build:66` is a bare `dependency('wayland-client')` with no version floor, so configure passes and the build dies later | libwayland **1.24** from the same pinned archive |

Issues 4 and 6 only surface deep into the build — 4 after all targets compile,
6 at target ~629 of 700. Issue 4 never appears in debug builds (LTO is off
there); issue 6 appears in every mode.

Issues 5 and 6 are both "noble is too old", but they differ in kind: 5 is a
declared requirement noble cannot meet, so it fails honestly at configure time.
6 is an **undeclared** requirement — the fix upstream is to add
`version: '>= 1.23'` to `meson.build:66` so it fails at configure time too.

None of these are reported upstream yet. `noctalia-ubuntu-bugreport.md` in this
repo covers the first four with reproductions, evidence and suggested fixes, and
is ready to post; 5 and 6 still need writing up.

## How the script fixes each one

- **apt** — README's list plus `gcc-14 g++-14 ninja-build pkg-config curl`, minus
  `libstb-dev`, filtered to packages with an actual candidate. There is no
  substitute for `libwireplumber-0.5-dev`: `libwireplumber-0.4-dev` would install
  and then be ignored, because `meson.build:91` asks pkg-config for
  `wireplumber-0.5` by name. The script stops with a pointer to the README rather
  than failing later at configure time.
- **wireplumber / wayland** — `ensure_wireplumber_05` and `ensure_wayland_123`
  both source from TUXEDO OS's `ubuntu-plasma` archive at
  `txos.tuxedocomputers.com` (*not* `deb.tuxedocomputers.com`, which ships no
  wireplumber at all), added **already pinned to priority 100** so it supplies
  only what noble cannot. Each checks the real condition first — `pkg-config
  --exists wireplumber-0.5`, and `wayland-client >= 1.23` — so on 26.04, where
  both are in the archives natively, neither touches apt sources at all. libwayland
  has to be installed by *exact version*, since the pin means a bare `apt-get
  install libwayland-dev` would reinstall noble's 1.22. See the WirePlumber
  section in `README.md` for the pin, its blast radius, and how it is verified.
- **just** — takes the first `just` >= 1.40.0, preferring `~/.local/bin`, and then
  calls it by **absolute path** for the rest of the run so a shadowed
  `/usr/bin/just` cannot interfere. Installs upstream into `~/.local/bin` if none
  is new enough.
- **stb** — if no system `stb_image_resize2.h`, downloads it (and
  `stb_image_write.h`) into `third_party/stb-compat/stb/` and puts
  `-I.../third_party/stb-compat` on `CPPFLAGS`. Pinned to stb commit
  `904aa67e1e2d1dec92959df63e700b166d5c1022`, not `master`.
- **compilers** — exports `CC=gcc-14 CXX=g++-14`, and deletes `build-<mode>` if
  its `meson-log.txt` names different compilers.

## Gotchas

- **Meson bakes `CPPFLAGS` in at `meson setup` time** and caches compiler
  detection per build dir. Changing `CC`/`CXX`/`CPPFLAGS` requires deleting
  `build-<mode>`; `--reconfigure` is not enough. `cc.has_header()` and the real
  compiles both read the baked-in flags.
- **`build-<mode>/meson-logs/install-log.txt` is the manifest `just uninstall`
  reads.** Deleting the build dir orphans whatever a previous `just install` put
  on the system, so run `just uninstall <mode>` first if you want those files
  gone. Watch for a build dir whose manifest prefix disagrees with its configured
  prefix — e.g. files installed under `/usr/local` by an earlier
  `sudo just install release`, with the dir now configured `--prefix $HOME/.local`.
  The script warns before removing such a dir.
- **`just build`'s `_ensure-configured` dependency calls a bare `just`** from
  `PATH` if `build.ninja` is missing. If an old apt `just` is first on `PATH`,
  that recursive call fails even when you invoked a new one by absolute path. Put
  `~/.local/bin` ahead of `/usr/bin`.
- **Untracked build output.** If the stb vendoring branch runs,
  `third_party/stb-compat/` appears as untracked in the Noctalia checkout.
- **Meson caches dependency *versions* too.** After upgrading libwayland in an
  already-configured tree, `meson-log.txt` keeps reporting
  `Dependency wayland-client found: YES 1.22.0 (cached)` while the compiler picks
  up the new 1.24 headers from the unchanged `/usr/include`. Harmless today
  precisely because `meson.build:66` declares no version floor — but if upstream
  adds `version: '>= 1.23'` (which they should), that stale cache would fail a
  reconfigure and the build dir needs deleting.

## What has actually been exercised

Two machines now (see below): the original TUXEDO OS box, and a **stock Ubuntu
24.04.4** box which is the more useful witness, because it has none of TUXEDO's
head start. Everything the previous revision of this table flagged as untested has
since run for real there.

| Path | Status |
|---|---|
| Release build with `CC=gcc-14 CXX=g++-14` | **Verified on both** — `[700/700] Linking target noctalia`, then `noctalia v5.0.0 (v5.0.0-beta.7-47-g7242ed4d4c31)`. No LTO bytecode mismatch, so workaround 4 holds |
| just detection picking 1.57.0 by absolute path | **Verified on both** |
| Pinned stb download | **Verified on both** — byte-identical (`diff -q`) to the header working at `/usr/local/include/stb/` |
| stb vendoring branch | **Verified on stock noble** — no system `stb_image_resize2.h`, so it downloaded both headers into `third_party/stb-compat/stb/` and built against them. Was the biggest untested risk; it is not any more |
| apt branch | **Verified on stock noble** |
| WirePlumber 0.5 via the pinned TUXEDO archive (gap 5) | **Verified on stock noble** — `Run-time dependency wireplumber-0.5 found: YES 0.5.15` against noble's PipeWire 1.2.4, pin held (`apt-get upgrade --dry-run` → 0 upgraded) |
| libwayland 1.24 via the same archive (gap 6) | **Verified on stock noble** — `pkg-config --modversion wayland-client` → 1.24.0, 6 packages upgraded, nothing else touched |
| Key fingerprint check | **Verified** — rejects on mismatch; needed `gpg --homedir` isolation, since a plain `gpg --show-keys` dies when `~/.gnupg` is not writable and would have rejected the genuine key |
| Pin rollback on guard mismatch | **Never run** — the pin has held every time, so the `remove_tuxedo_repo` path is still untested |
| 26.04 release guard (`needs_noble_workarounds`) | **Never run** — no resolute box here; the 26.04 versions it relies on were verified against the archive index, not by executing the branch |
| `--install` branch | **Verified on stock noble** — binary at `~/.local/bin/noctalia`, assets under `~/.local/share/noctalia` |
| Stale-build-dir removal | **Never run** |
| A clean (`rm -rf build-release`) build | **Verified on stock noble** — the 700-target figure above is from a cold build dir |

## Doing it by hand

If the script is not wanted, this is the whole thing:

```sh
# the only root step
sudo apt-get install -y g++-14 gcc-14 meson ninja-build   # plus README's list, minus libstb-dev

# just >= 1.40
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
  | bash -s -- --to "$HOME/.local/bin"

# the missing stb header, anywhere on the include path
mkdir -p ~/.local/include/stb
curl -sSfL https://raw.githubusercontent.com/nothings/stb/904aa67e1e2d1dec92959df63e700b166d5c1022/stb_image_resize2.h \
  -o ~/.local/include/stb/stb_image_resize2.h

# both compilers, and a fresh build dir
rm -rf build-release
CC=gcc-14 CXX=g++-14 CPPFLAGS="-I$HOME/.local/include" \
  just configure release "$HOME/.local"
just build release
just install release
```

## Reference environments

| | Stock noble (primary) | TUXEDO OS (original) |
|---|---|---|
| OS | Ubuntu 24.04.4 LTS ("noble") | TUXEDO OS 24.04.4 LTS (noble base) |
| Kernel | 6.8.0-136-generic | 6.17.0-122035-tuxedo |
| Shell | zsh | zsh |
| Noctalia | 5.0.0, commit `7242ed4d4`, branch `main` | 5.0.0, commit `ae6113f02`, branch `main` |
| Meson | 1.3.2 | 1.6.1 |
| just | 1.57.0 at `~/.local/bin/just` | 1.57.0 at `~/.local/bin/just` |
| Default compiler | g++ 13.3.0 — too old; build uses g++-14 / gcc-14 (14.2.0) | same |
| WirePlumber | daemon 0.4.17 (noble), dev lib 0.5.15-1~tux1 (pinned archive) | 0.5.15 from the distro |
| libwayland | 1.24.0-1~tux1 (pinned archive) | 1.24 from the distro |

The stock-noble column is the one to trust for "will this work on a fresh box" —
TUXEDO OS already ships WirePlumber 0.5 and libwayland 1.24, so gaps 5 and 6 are
invisible there.
