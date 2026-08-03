# Hyprland and Noctalia config files and tools

## Usage

```sh
git clone https://github.com/maddingo/hypr-config ~/.hypr-config
~/.hypr-config/install.sh
```

Symlinks `config-hypr` to `~/.config/hypr` and `config-noctalia` to `~/.config/noctalia`. An existing directory at either target is backed up as `<name>.backup-<timestamp>`.

**Run this with Hyprland not running** — from a TTY (Ctrl+Alt+F3) or before
logging in. `install.sh` refuses to start otherwise, up front rather than after
the Noctalia build. Hyprland picks its config path once at startup (`hyprland.lua`
if present, else the legacy `hyprland.conf`) and never revisits that choice on
reload, so replacing `~/.config/hypr` under a live session makes it re-read the
path it already latched onto; finding nothing there, it writes a stub config —
into *this repo*, through the symlink just created — and runs off it. The
symptom is a session with about six keybinds and default styling.
`HYPR_ALLOW_LIVE_RELINK=1` overrides the check. `config-hypr/hyprland.conf` is
gitignored so a stub can never be committed by accident.

The guard covers the whole script, so building Noctalia from inside a Hyprland
session means calling `install-noctalia.sh --install` directly (see
`noctalia-install.md`) — that part is safe with the compositor up.

If `Hyprland` is not on `PATH` and this is an Ubuntu 24.04 base, it is installed
first via [Ubuntu-Hyprland](https://github.com/LinuxBeginnings/Ubuntu-Hyprland),
driven by `hyprland-preset.sh` so its own dotfiles are skipped in favour of this
repo's. That step needs sudo and still asks a few questions.

If `noctalia` is not on `PATH`, it is built next — see `noctalia-install.md`.

| Variable | Default | Purpose |
|---|---|---|
| `HYPRLAND_SRC` | `~/Develop/Ubuntu-Hyprland` | Ubuntu-Hyprland checkout; cloned if absent, reused if present. |
| `NOCTALIA_SRC` | `~/Develop/noctalia` | Noctalia checkout to build in; cloned if absent, reused if present. |

## What noble is too old for: WirePlumber 0.5 and libwayland 1.23

**Status: implemented in `install-noctalia.sh` (`ensure_wireplumber_05` and
`ensure_wayland_123`), both exercised for real on this machine.** Each is skipped
automatically when its condition is already met — `pkg-config --exists
wireplumber-0.5`, and `wayland-client >= 1.23` — or when the configured archives
carry the package natively (26.04+), so the whole thing no-ops everywhere except
stock noble. `--no-tuxedo-repo` disables it entirely.

Two of Noctalia's requirements are newer than anything noble ships. They fail very
differently, which is worth understanding before trusting the fix.

**WirePlumber 0.5** fails honestly, at configure time:

```
Run-time dependency wireplumber-0.5 found: NO (tried pkgconfig and cmake)
meson.build:91:22: ERROR: Dependency "wireplumber-0.5" not found
```

Noble ships WirePlumber **0.4.17** and nothing newer; WirePlumber 0.5.0 was
released in March 2024, just after noble's feature freeze. Noctalia's
`meson.build:91` requires 0.5 with no fallback and no meson option to disable it.

**libwayland 1.23** fails silently at configure and then blows up 629 targets into
the build:

```
../src/wayland/virtual_keyboard_service.cpp:95:19: error:
  ‘wl_proxy_get_display’ was not declared in this scope
```

`wl_proxy_get_display` was added in wayland **1.23.0** — verified by bisecting the
upstream `wayland-client-core.h`: absent in 1.22.0, present from 1.23.0 onward.
Noble ships 1.22.0. This one gets through configure because `meson.build:66` is a
bare `dependency('wayland-client')` with **no version floor**, so meson has nothing
to check. There is exactly one call site in the whole tree, and it only wants a
`wl_display*` to pass to `wl_display_flush`.

### Decision

Take both from **TUXEDO OS's `ubuntu-plasma` archive** — WirePlumber
**0.5.15-1~tux1** and libwayland **1.24.0-1~tux1** — pinned so it can supply
nothing else. The WirePlumber *daemon* stays at noble's 0.4.17. No dummy package
is needed; unlike the pipewire-debian PPA, these debs declare honest dependencies.

```sh
# TUXEDO signing key — fingerprint E5D0C320BBCE8D21CDF60DD5120ED28D54840598
curl -fsSL https://deb.tuxedocomputers.com/0x54840598.pub.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/tuxedo.gpg

echo "deb [signed-by=/usr/share/keyrings/tuxedo.gpg] https://txos.tuxedocomputers.com/ubuntu-plasma noble main" \
  | sudo tee /etc/apt/sources.list.d/tuxedo-plasma.list

# MANDATORY pin — see the warning below. Default-deny the whole archive.
sudo tee /etc/apt/preferences.d/tuxedo-plasma >/dev/null <<'EOF'
Package: *
Pin: origin "txos.tuxedocomputers.com"
Pin-Priority: 100
EOF

sudo apt-get update
sudo apt-get install -y libwireplumber-0.5-dev

# libwayland must be by EXACT version: the pin keeps it below noble's 1.22, so a
# bare `apt-get install libwayland-dev` would just reinstall the old one. The six
# move in lockstep (each Depends: (= ${binary:Version})).
sudo apt-get install -y \
  libwayland-dev=1.24.0-1~tux1 libwayland-client0=1.24.0-1~tux1 \
  libwayland-server0=1.24.0-1~tux1 libwayland-cursor0=1.24.0-1~tux1 \
  libwayland-egl1=1.24.0-1~tux1 libwayland-bin=1.24.0-1~tux1
```

Why taking libwayland is acceptable even though the pin exists to prevent exactly
this: its dependency closure is `libc6 (>= 2.38)` and `libffi8 (>= 3.4)`, both
already satisfied by stock noble. `apt-get install -s` confirms it — **6 upgraded,
0 newly installed, 0 to remove** — no Qt, KDE, Mesa or PipeWire pulled in.
libwayland's ABI is strictly additive under a soname unchanged since 2012, so new
libs under old binaries is the safe direction. A running compositor keeps its
mapped copy; the swap takes effect for clients started afterwards.

Note that after this, `apt-cache policy libwayland-client0` reports 1.24 as the
*candidate*, not noble's 1.22 — apt will not offer a downgrade. That keeps
`apt-get upgrade` a no-op rather than a fight. It also means `libwayland-client0`
can no longer serve as a canary for the pin leaking, which is why the script's
guard list swaps it for `libgbm1` and `libqt6core6t64`.

`Pin: origin "<host>"` matches the **site hostname**, whereas `Pin: release o=…`
matches the `Release` file's `Origin:` field. Both TUXEDO archives declare the
same `Origin: TUXEDO Computers`, so the hostname form is the one that scopes this
pin to `txos` alone and leaves `deb.tuxedocomputers.com` untouched if it is ever
added for hardware drivers.

No per-package `Pin-Priority: 600` block is needed. Priority 100 lands in the
`100 ≤ P < 500` band — "install unless a version from another distribution is
available" — which does both jobs at once: the 186 contested packages lose to
Ubuntu's 500, while `libwireplumber-0.5-{0,dev}` and `gir1.2-wp-0.5` have no
competing version anywhere and so stay installable on request.

### Why this source, and why the pin is not optional

**Dependencies are clean.** Verified 2026-08-02 against the live index:

```
libwireplumber-0.5-dev 0.5.15-1~tux1
  Depends: ... libglib2.0-dev, libpipewire-0.3-dev, libwireplumber-0.5-0 (= 0.5.15-1~tux1)
libwireplumber-0.5-0 0.5.15-1~tux1
  Depends: libc6 (>= 2.38), libglib2.0-0t64 (>= 2.68), liblua5.4-0 (>= 5.4.6),
           libpipewire-0.3-0t64 (>= 1.1.81), libsystemd0
wireplumber-0.5.pc
  Requires.private: gmodule-2.0 >= 2.68, libpipewire-0.3 >= 1.0.2
```

Every one is already satisfied here: PipeWire **1.2.4** from `cppiber/hyprland`
clears both the `>= 1.1.81` and the `>= 1.0.2` floors, and `liblua5.4-0` 5.4.6 is
already installed. It depends on the **real** `libpipewire-0.3-dev`, not the
phantom virtual package the pipewire-debian PPA asks for — the same shape Ubuntu
26.04 ships.

**⚠ The pin is mandatory, not hygiene.** This is not a narrow PPA — it is a
**4,987-package full Plasma/Ubuntu overlay**. Measured against this box on
2026-08-02: it carries **196** of the installed packages, **186** of them at
higher versions, and offers **2,732** more that are not installed. Adding a repo
does not merely make packages available, it makes them *candidates* at the
default priority **500** — the same as Ubuntu's — and ties are broken by version
number, which TUXEDO's `~tux1` builds win. So the next plain `apt upgrade`, not
even an install, would take all 186:

| Package | Installed | Archive offers |
|---|---|---|
| `libpipewire-0.3-0t64`, `pipewire`, `pipewire-pulse` | 1.2.4-1ppa1 | **1.6.8-1~tux1** |
| `libegl-mesa0`, `libgbm1`, `libglx-mesa0`, `mesa-vulkan-drivers` | 25.2.8-0ubuntu0.24.04.2 | **26.1.4-1~24.04-tux1** |
| `libwayland-client0`, `-server0`, `-egl1`, `-dev` | 1.22.0-2.1build1 | **1.24.0-1~tux1** (taken deliberately — see above) |
| `libinput10`, `libinput-bin` | 1.31.1-1 | 1.31.1-1ubuntu1~tux1 |
| `apparmor`, `libapparmor1` | 4.0.1 | 4.1.3-2~really4.0.1~tux3 |
| `cmake`, `cmake-data` | 3.28.3-1build7 | **4.2.3-2ubuntu2~tux1** |

Seventy-two of the 186 are KDE/Qt. Mesa would jump a major version and PipeWire
would be replaced out from under `cppiber/hyprland`. The `cmake` 3.28 → 4.2 jump
is a separate hazard:
CMake 4 dropped compatibility with `cmake_minimum_required(VERSION <3.5)`, so
unrelated projects on this box would stop configuring.

The `Breaks: libpipewire-0.3-0 (<< 1.6.8-1~tux1)` on their `libpipewire-0.3-0t64`
is not itself the danger — it is what removes the escape hatch. The installed
1.2.4 package `Provides: libpipewire-0.3-0 (= 1.2.4-1ppa1)`, which that `Breaks`
matches, so no partial PipeWire state is reachable: once apt starts, the whole
stack moves together.

The `Pin-Priority: 100` default-deny is what makes this archive safe to have in
`sources.list.d` at all.

The pin also keeps `wireplumber` 0.5.15 from becoming the candidate for the
*daemon*, which would otherwise swap the session manager on the next
`apt upgrade`. 0.5 replaced 0.4's Lua script configuration with `.conf`
fragments, so that is a behavioural change, not a routine bump.

Verify the pin took effect — a wrong hostname fails silently:

```sh
apt-cache policy wireplumber pipewire libpipewire-0.3-0t64 libegl-mesa0 libgbm1 cmake
#   every Candidate must be unchanged: 0.4.17-1ubuntu4.1, 1.2.4-1ppa1,
#   1.2.4-1ppa1, 25.2.8-0ubuntu0.24.04.2, 25.2.8-0ubuntu0.24.04.2, 3.28.3-1build7

apt-get install --dry-run libwireplumber-0.5-dev   # exactly 3 new, 0 upgraded
apt-get upgrade --dry-run                          # 0 upgraded — the real test
```

`install-noctalia.sh` runs this check itself: it snapshots the candidate versions
of `pipewire`, `libpipewire-0.3-0t64`, `libegl-mesa0`, `libgbm1`,
`libqt6core6t64` and `cmake` before and after adding the archive, and if any of
them moves it deletes the `sources.list.d` and `preferences.d` files, re-runs
`apt-get update` and aborts rather than leaving an unpinned overlay in place.
`libwayland-client0` was a canary until libwayland was deliberately taken from the
archive; `libgbm1` (Mesa 26.1.4 vs noble's 25.2.8) and `libqt6core6t64` (6.10.2 vs
6.4.2) replace it, both being packages the archive overrides hard.

**What the pin does not protect against.** `libwireplumber-0.5-0 0.5.15-1~tux1`
is *compiled* against PipeWire 1.6.x but only *declares* `libpipewire-0.3-0t64
(>= 1.1.81)`, and its `.pc` asks for `libpipewire-0.3 >= 1.0.2`. Pinned, it runs
against **1.2.4**. That is the maintainer's own compatibility assertion and
PipeWire holds its 0.3 ABI stable, so it should hold — but it is a combination
TUXEDO never tests, since their users run 0.5.15 against 1.6.8. If Noctalia's
volume control misbehaves, suspect this first; the symptom is already
instrumented at `wireplumber_mixer.cpp:126-130`, which logs
`device volume control unavailable after 5s (mixer-api …, default-nodes-api …)`.

**Why a 0.5 library over a 0.4 daemon is safe.** Noctalia uses WirePlumber purely
as an in-process library: `src/pipewire/wireplumber_mixer.cpp:65-67` does
`wp_core_new` → `wp_core_connect`, which talks to the **PipeWire** daemon, then
loads `mixer-api` and `default-nodes-api` in-process. It never contacts the
WirePlumber session manager. The sonames differ (`libwireplumber-0.5.so.0` vs
`0.4.so.0`) and neither package declares `Conflicts`/`Breaks` against the other,
so the two coexist.

### Alternatives rejected

| Option | Why not |
|---|---|
| Keep the current `libwireplumber-0.4-dev` fallback | Cosmetic only. `meson.build:91` hard-requires 0.5, so this installs a package the build then refuses to use — it does not prevent the error above. |
| `ppa:pipewire-debian/wireplumber-upstream` | Has 0.5.2, but `libwireplumber-0.5-dev` there declares `Depends: ... libpipewire-1.0.2-dev`, a Debian versioned-API virtual name that **nothing** in noble, `cppiber/hyprland`, or even pipewire-debian's own `pipewire-upstream` PPA provides — the string appears in those indexes only inside that one `Depends` line. Uninstallable as shipped; needs an `equivs` dummy to work around. Adding `pipewire-upstream` too does not fix it and actively hurts: it is on PipeWire **1.0.7**, older than the installed 1.2.4, and pins `libpipewire-0.3-0` to an exact equal version. |
| `deb.tuxedocomputers.com/ubuntu` (the *other* TUXEDO archive) | Wrong TUXEDO repo — publishes **no wireplumber package in any suite** (`noble`, `noble-nvidia`, `stable`, `resolute`, `jammy`, …) across `main`/`debug`/`non-free`/`contrib`. Its `noble` archive is 694 packages of hardware, drivers and branding. The WirePlumber packages are in `txos.tuxedocomputers.com/ubuntu-plasma` instead. |
| KDE neon | TUXEDO OS's KDE stack source, so a plausible guess — but it has PipeWire 1.2.6 and **no wireplumber packages at all** across its 19,767. Grafting neon onto stock Ubuntu is its own hazard regardless. |
| `dpkg -x` the `-dev` deb instead of the dummy | Works, but puts headers and `wireplumber-0.5.pc` outside dpkg's database, so nothing tracks, upgrades or removes them. |
| Patch Noctalia to build against 0.4 | Viable and self-contained — every symbol it uses exists in 0.4, and only two differ: `wp_core_new` takes 2 args in 0.4 vs the 3 passed, and `wp_core_load_component` is synchronous in 0.4 vs the async form plus `_finish`. ~25 lines. Rejected as a patch against a third-party checkout that upstream can break at any time. |
| Build WirePlumber 0.5 from source into a private prefix | Safe for the same in-process reason, but a much larger moving part to carry in this repo. |
| Patch out the `wl_proxy_get_display` call instead of upgrading libwayland | One call site, and `WaylandConnection::display()` already exists at `wayland_connection.h:165` — but `VirtualKeyboardService` is deliberately decoupled from it (its header only forward-declares `wl_seat` and holds no connection), so threading a display through means editing the header, the `.cpp` and the caller. A three-file patch against a third-party checkout, versus a six-package upgrade with a `libc6`+`libffi8` closure. The stb workaround is a dropped-in header; this is not comparable. |

### This is noble-only

Ubuntu **26.04 "resolute"** (released 2026-04-23) fixes both natively. Verified
2026-08-02 against `dists/resolute/main/binary-amd64/Packages.xz`:

```
libwireplumber-0.5-dev   0.5.13-1ubuntu1
libwayland-dev           1.24.0-2          (source: wayland)
```

`libwireplumber-0.5-dev` there depends on the real `libpipewire-0.3-dev` rather
than the phantom virtual package, and 1.24.0 is well past the 1.23 floor. On 26.04
this whole section collapses to `apt install libwireplumber-0.5-dev
libwayland-dev`, and the archive and the pin should both be dropped.

`install-noctalia.sh` guards on the release itself: `needs_noble_workarounds`
reads `VERSION_ID` from `/etc/os-release` and skips `ensure_wireplumber_05` and
`ensure_wayland_123` entirely from `UBUNTU_FIXED_IN=26.04` onward, so the TUXEDO
archive is never even considered there. That is deliberately stricter than the
per-package checks inside those two functions, which would also no-op on 26.04
but only *after* deciding the packages happen to be available. A non-Ubuntu
`/etc/os-release` reads as "unknown" and still runs the workarounds, where
`setup_tuxedo_repo`'s existing noble-only check catches it.

