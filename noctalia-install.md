# Installing Noctalia on Ubuntu 24.04

Noctalia's README does not build on Ubuntu 24.04 "noble" as written. This
documents why, and what `install-noctalia.sh` does about it. Verified on
**2026-08-02** against Noctalia `5.0.0` at commit `ae6113f02`.

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
```

Expect a long build (536 targets). The `apt` step is the only one needing root;
the script prints the exact `apt-get install` line before running it, and
`--no-apt` skips it if you would rather run it yourself.

## What breaks, and why

Four separate things, each hidden behind the previous — they can only be found by
hitting them in sequence.

| # | Break | Root cause | Fix |
|---|---|---|---|
| 1 | `just configure release` → `Non-default parameter 'args' follows default parameter` at `justfile:48` | apt ships just `1.21.0`; variadic-after-default needs just **1.40.0** (casey/just#2660). just parses the whole file before dispatch, so *every* recipe dies and the error misleadingly names `test` | upstream just in `~/.local/bin` |
| 2 | `stb/stb_image_resize2.h not found` at `meson.build:192` | `libstb-dev` is a 2023-01-29 snapshot; ships `stb_image_resize.h` (v1, different API) and `stb_image_write.h`, not resize2 | vendor the single header, add to `CPPFLAGS` |
| 3 | `fatal error: print: No such file or directory` | 10 sources `#include <print>`; libstdc++ got it in **GCC 14**, but `README.md:220` claims GCC 13+ and lists Ubuntu 24.04 as fine. This is a *library* floor — Clang 16 over libstdc++ 13 fails identically | `g++-14` |
| 4 | `lto1: fatal error: bytecode stream ... generated with LTO version 13.1 instead of the expected 14.0`, at the final link | `README.md:222` says `CXX=g++-13 just configure`. Setting only `CXX` leaves Meson to detect C separately and fall back to default gcc. Generated Wayland protocol sources are C, and release builds set `-Db_lto=true` | set **both** `CC` and `CXX` |

Issue 4 only surfaces after all 536 targets compile, and never in debug builds
(LTO is off there).

None of these are reported upstream yet. `noctalia-ubuntu-bugreport.md` in this
repo covers all four with reproductions, evidence and suggested fixes, and is
ready to post.

## How the script fixes each one

- **apt** — README's list plus `gcc-14 g++-14 ninja-build pkg-config curl`, minus
  `libstb-dev`. Filters to packages with an actual candidate first and falls back
  to `libwireplumber-0.4-dev` where 0.5 is missing (stock noble has 0.4; TUXEDO
  PPAs have 0.5).
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

## What has actually been exercised

The script works end to end on the machine below, but some branches have never
run — worth knowing before trusting it on a fresh box:

| Path | Status |
|---|---|
| Release build with `CC=gcc-14 CXX=g++-14` | **Verified** — `[536/536] Linking target noctalia`, then `noctalia v5.0.0 (v5.0.0-beta.6-86-gae6113f0282a)` |
| just detection picking 1.57.0 by absolute path | **Verified** |
| Pinned stb download | **Verified** — byte-identical (`diff -q`) to the header already working at `/usr/local/include/stb/` |
| stb vendoring branch | **Not exercised** — this box already has `/usr/local/include/stb/stb_image_resize2.h`, so the script skipped it. This is the branch most likely to matter on a stock noble machine |
| apt branch | **Never run** |
| `--install` branch | **Never run** |
| Stale-build-dir removal | **Never run** |
| A clean (`rm -rf build-release`) build | **Not done** |

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

## Reference environment

| | |
|---|---|
| OS | TUXEDO OS 24.04.4 LTS (Ubuntu 24.04 "noble" base) |
| Kernel | 6.17.0-122035-tuxedo |
| Shell | zsh |
| Noctalia | 5.0.0, commit `ae6113f02`, branch `main` |
| Meson | 1.6.1 |
| just | 1.57.0 at `~/.local/bin/just` |
| Default compiler | g++ 13.3.0 — too old; build uses g++-14 / gcc-14 (14.2.0) |
