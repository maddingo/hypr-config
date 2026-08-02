# Debian/Ubuntu build instructions are broken on Ubuntu 24.04 LTS (four issues)

## Summary

Following the README's Debian/Ubuntu instructions on a clean Ubuntu 24.04 LTS
system fails at four separate points. Two are packages in the documented `apt`
line that are too old to satisfy the build; one is a stated compiler requirement
that is a major version too low; one is incomplete guidance for pointing Meson at
an alternate compiler. None of them are reachable by following the README as
written — each has to be diagnosed and worked around before the next appears.

The Arch, Fedora, and openSUSE dependency lists appear fine. This is specific to
the `apt` path.

## Environment

| | |
|---|---|
| OS | TUXEDO OS 24.04.4 LTS (Ubuntu 24.04 "noble" base) |
| Kernel | 6.17.0-122035-tuxedo |
| Noctalia | 5.0.0, commit `ae6113f02` |
| Meson | 1.6.1 |
| Default compiler | g++ (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |

---

## 1. `just` in the Ubuntu archive cannot parse the justfile

`README.md:154` installs `just` via `apt`. On Ubuntu 24.04 that is version
`1.21.0-1` (from `noble/universe`), which rejects the justfile outright:

```
$ just configure release
error: Non-default parameter `args` follows default parameter
  ——▶ justfile:48:14
   │
48 │ test m=mode *args: (_ensure-configured m)
   │              ^^^^
```

`justfile:48` places a variadic `*args` after the defaulted `m=mode`. Support for
that landed in **just 1.40.0** (2025-03-09) — "Star parameters may follow default
parameters", casey/just#2660.

Because `just` parses the entire justfile before dispatching, **every** recipe
fails, not just `test`. `just configure`, `just build`, and `just --list` are all
unusable. The error names `test`, which sends you looking in the wrong place.

**Suggested fix:** document a minimum `just` version, and note that the Ubuntu
package does not meet it (point users at the upstream installer or a `cargo
install`). Alternatively, rewrite the `test` recipe signature so it parses on
older `just` — e.g. drop the default from `m` — which would keep the documented
`apt` line working.

## 2. `libstb-dev` on Ubuntu 24.04 does not ship `stb_image_resize2.h`

`README.md:166` installs `libstb-dev`. On Ubuntu 24.04 that package is
`0.0~git20230129.5736b15+ds-1.2` — a snapshot from 2023-01-29, predating
`stb_image_resize2.h` upstream. Configure fails at `meson.build:192`:

```
stb/stb_image_resize2.h not found
```

`dpkg -L libstb-dev` shows what is actually provided:

```
/usr/include/stb/stb_image_resize.h     <- v1, deprecated, different API
/usr/include/stb/stb_image_write.h      <- present; the second check passes
```

So `stb_image_write.h` is satisfied and only the resize2 check fails. The v1
header is not a drop-in substitute.

Affected sources:

- `src/render/core/stb_image_resize_impl.cpp`
- `src/render/core/image_file_loader.cpp`
- `src/render/core/thumbnail_service.cpp`
- `src/capture/screenshot_service.cpp`

**Workaround used:** drop the single upstream header into a directory on the
include path (`~/.local/include/stb/stb_image_resize2.h`) and pass
`CPPFLAGS=-I$HOME/.local/include` at `meson setup` time.

**Suggested fix:** since stb is header-only and the distro packaging lags,
consider vendoring `stb_image_resize2.h` under `third_party/` with a Meson
fallback when the system header is absent — the same treatment `fzy`, `luau`,
`wuffs`, and `material_color_utilities` already get. Failing that, document the
Ubuntu gap explicitly.

## 3. Stated compiler requirement is one major version too low

`README.md:220-221` says:

> The sources are built as C++23, which requires GCC 13+ or Clang 16+. Current
> rolling and recent stable distros (Arch, Fedora 38+, Debian 13, Ubuntu 24.04+)
> ship a new enough compiler by default.

Ubuntu 24.04 ships GCC 13.3, which the README explicitly lists as sufficient. It
is not:

```
src/main.cpp:21:10: fatal error: print: No such file or directory
   21 | #include <print>
      |          ^~~~~~~
```

`<print>` was implemented in libstdc++ for **GCC 14** (committed 2023-12, released
in GCC 14); there is no `/usr/include/c++/13/print`. Ten files include it:

```
src/main.cpp:21                             src/scripting/plugin_lint.cpp:11
src/ipc/ipc_client.cpp:8                    src/launcher/dmenu_cli.cpp:8
src/theme/cli.cpp:25                        tests/plugin_manifest_test.cpp:9
src/theme/firefox_theme/firefox_theme.cpp:18  tests/plugin_bindings_test.cpp:11
src/config/cli.cpp:20                       tests/config_migration_test.cpp:7
```

Note this is a **library** requirement, not a front-end one — Clang 16 reading
libstdc++ 13 fails identically. The real floor is GCC 14+, or Clang with a libc++
new enough to provide `<print>`.

**Suggested fix:** change the requirement to GCC 14+ / Clang 17+ (with libc++),
and remove Ubuntu 24.04 from the "ships a new enough compiler by default" list.
Debian 13 (GCC 14) is fine; Ubuntu 24.04 is not.

## 4. `CXX=g++-N` alone is insufficient for release builds (LTO mismatch)

`README.md:222` advises pointing Meson at a newer compiler with:

> `CXX=g++-13 just configure`

Setting only `CXX` leaves Meson to detect the C compiler independently, which
falls back to the system default. The project builds generated Wayland protocol
sources as C, so a release build (`-Db_lto=true`) links C bytecode from one GCC
against C++ bytecode from another:

```
$ CXX=g++-14 just configure release && just build release
[697/697] Linking target noctalia
FAILED: noctalia
lto1: fatal error: bytecode stream in file
  'libnoctalia_core.a.p/meson-generated_.._xdg-output-unstable-v1-client-protocol.c.o'
  generated with LTO version 13.1 instead of the expected 14.0
```

From `build-release/meson-logs/meson-log.txt`:

```
C compiler for the host machine:   cc     (gcc 13.3.0)
C++ compiler for the host machine: g++-14 (gcc 14.2.0)
```

This surfaces only at the final link, after all 697 targets compile — an expensive
way to discover a configure-time mistake. It does not appear in debug builds,
where LTO is off.

**Suggested fix:** update the README to set both, `CC=gcc-N CXX=g++-N just
configure`, and/or ship a `--native-file` example. A Meson-side check that the C
and C++ compiler versions match when `b_lto` is enabled would turn this into a
clear configure-time error.

---

## Working invocation on Ubuntu 24.04

For anyone hitting this before the docs are updated — after installing `just`
>= 1.40 outside the archive, placing `stb_image_resize2.h` on the include path,
and installing `g++-14`:

```bash
rm -rf build-release
CC=gcc-14 CXX=g++-14 CPPFLAGS="-I$HOME/.local/include" \
  just configure release "$HOME/.local"
just build release
just install release
```

With all four worked around, `build-release` compiles and links all 536 targets
and the binary reports `noctalia v5.0.0 (v5.0.0-beta.6-86-gae6113f0282a)`, so
these four appear to be the complete set of blockers on 24.04.

## Note on scope

The four issues were each found by hitting them in sequence. Happy to open them
as separate issues if you'd prefer them tracked individually.
