#!/usr/bin/env bash
#
# install-noctalia.sh — build Noctalia on Ubuntu 24.04 LTS "noble".
#
# The README's Debian/Ubuntu instructions do not work as written on 24.04.
# This script works around the six gaps:
#
#   1. apt's `just` is 1.21.0; the justfile needs >= 1.40.0 to parse at all.
#      -> installs upstream just into ~/.local/bin.
#   2. apt's `libstb-dev` is a 2023 snapshot without stb_image_resize2.h.
#      -> vendors that single header into third_party/stb-compat/.
#   3. The README claims GCC 13+ is enough; <print> needs GCC 14's libstdc++.
#      -> installs and uses gcc-14/g++-14.
#   4. Setting only CXX leaves Meson to pick the default C compiler, so release
#      builds die at link time with an LTO bytecode version mismatch.
#      -> sets both CC and CXX.
#   5. meson.build hard-requires wireplumber-0.5; noble ships only 0.4.17 and
#      Noctalia has no fallback for it.
#      -> adds TUXEDO's ubuntu-plasma archive, pinned to supply nothing else.
#   6. src/wayland/virtual_keyboard_service.cpp uses wl_proxy_get_display, added
#      in wayland 1.23; noble has 1.22 and meson.build:66 declares no floor, so
#      this only shows up ~630 targets into the build.
#      -> takes libwayland 1.24 from the same pinned archive, by exact version.
#
# Usage:
#   ./install-noctalia.sh                 # apt deps, configure, build (release)
#   ./install-noctalia.sh --no-apt        # skip apt; everything else
#   ./install-noctalia.sh --install       # also `just install` into --prefix
#   ./install-noctalia.sh --mode debug    # debug build instead of release
#   ./install-noctalia.sh --prefix /usr/local
#   ./install-noctalia.sh --no-tuxedo-repo   # never touch apt sources
#
# The only step needing root is the apt install. It is printed before it runs,
# and can be skipped with --no-apt if you prefer to run it yourself.

set -euo pipefail

MODE=release
PREFIX="$HOME/.local"
DO_APT=1
DO_INSTALL=0
DO_TUXEDO_REPO=1

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$REPO_DIR/third_party/stb-compat"

# stb has no releases; pinned to the last commit touching this header.
STB_COMMIT=904aa67e1e2d1dec92959df63e700b166d5c1022
STB_URL="https://raw.githubusercontent.com/nothings/stb/$STB_COMMIT/stb_image_resize2.h"

JUST_MIN=1.40.0
GCC_SUFFIX=14

# First Ubuntu release needing none of the WirePlumber/libwayland workarounds.
UBUNTU_FIXED_IN=26.04

# Source for both WirePlumber 0.5 and libwayland 1.24. TUXEDO's ubuntu-plasma
# archive, *not* the similarly named deb.tuxedocomputers.com (which ships no
# wireplumber at all) and not ppa:pipewire-debian/wireplumber-upstream (whose
# libwireplumber-0.5-dev depends on a virtual libpipewire-1.0.2-dev that nothing
# in noble provides).
TUXEDO_SITE="txos.tuxedocomputers.com"
TUXEDO_LIST=/etc/apt/sources.list.d/tuxedo-plasma.list
TUXEDO_PREFS=/etc/apt/preferences.d/tuxedo-plasma
TUXEDO_KEYRING=/usr/share/keyrings/tuxedo.gpg
TUXEDO_KEY_URL="https://deb.tuxedocomputers.com/0x54840598.pub.asc"
TUXEDO_KEY_FPR="E5D0C320BBCE8D21CDF60DD5120ED28D54840598"

# wl_proxy_get_display landed in wayland 1.23.0 (absent in 1.22.0, which is what
# noble ships). Only libwayland is taken from TUXEDO besides wireplumber; its
# whole dependency closure is libc6 and libffi8, both satisfied by stock noble,
# so this pulls in no Qt, KDE, Mesa or PipeWire.
WAYLAND_MIN=1.23.0
WAYLAND_PKGS=(
    libwayland-dev libwayland-client0 libwayland-server0
    libwayland-cursor0 libwayland-egl1 libwayland-bin
)

# The archive is a 4987-package Plasma overlay carrying PipeWire 1.6.8, Mesa 26.x,
# libwayland 1.24 and CMake 4 — 186 packages installed here have a higher version
# in it. The pin is what keeps all of that out, so these canaries are checked
# before and after adding it; if any candidate moves, the pin did not hold.
# libwayland-client0 was a canary until gap 6; it cannot be one any more now that
# it is deliberately sourced from the archive, so libgbm1 (Mesa 26.1.4 vs noble's
# 25.2.8) and libqt6core6t64 (6.10.2 vs 6.4.2) cover that ground instead.
TUXEDO_GUARD_PKGS=(pipewire libpipewire-0.3-0t64 libegl-mesa0 libgbm1 libqt6core6t64 cmake)

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m warning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
    exit 0
}

while (( $# )); do
    case "$1" in
        --no-apt)   DO_APT=0 ;;
        # --no-wireplumber-repo is the old name, kept working: the archive now
        # supplies libwayland too, so the flag is no longer wireplumber-specific.
        --no-tuxedo-repo|--no-wireplumber-repo) DO_TUXEDO_REPO=0 ;;
        --install)  DO_INSTALL=1 ;;
        --mode)     MODE="${2:?--mode needs an argument}"; shift ;;
        --prefix)   PREFIX="${2:?--prefix needs an argument}"; shift ;;
        -h|--help)  usage ;;
        *)          die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

case "$MODE" in
    release|debug|asan) ;;
    *) die "unknown mode: $MODE (expected release, debug, or asan)" ;;
esac

[[ -f "$REPO_DIR/meson.build" && -f "$REPO_DIR/justfile" ]] \
    || die "$REPO_DIR does not look like a Noctalia checkout"

# True when $1 >= $2, comparing dotted version numbers.
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# Candidate version apt would install, empty when there is none.
apt_candidate() {
    apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" { print $2 }'
}

# Ubuntu release as a dotted number ("24.04"), empty on anything that is not
# Ubuntu. Callers must treat empty as "unknown", not as "old".
ubuntu_version() {
    [[ -r /etc/os-release ]] || return 0
    (. /etc/os-release; [[ "${ID:-}" == ubuntu ]] && printf '%s' "${VERSION_ID:-}")
}

# True when this release still needs the noble workarounds below. 26.04
# "resolute" carries libwireplumber-0.5-dev 0.5.13-1ubuntu1 and libwayland-dev
# 1.24.0-2 in main, so from there on the TUXEDO archive must never be considered
# at all — not merely skipped once its packages happen to be found.
needs_noble_workarounds() {
    local rel
    rel="$(ubuntu_version)"
    [[ -z "$rel" ]] && return 0
    ! version_ge "$rel" "$UBUNTU_FIXED_IN"
}

# ── The TUXEDO archive (WirePlumber 0.5, libwayland 1.24) ────────────────────

# meson.build:91 asks pkg-config for wireplumber-0.5 and nothing else, so this is
# the exact condition that decides whether any of the below is needed.
have_wireplumber_05() { pkg-config --exists wireplumber-0.5 2>/dev/null; }

tuxedo_guard_snapshot() {
    local pkg
    for pkg in "${TUXEDO_GUARD_PKGS[@]}"; do
        printf '%s=%s\n' "$pkg" "$(apt_candidate "$pkg")"
    done
}

# Version of $1 offered specifically by the TUXEDO archive, empty if it offers
# none. apt-cache policy is no use here — the pin deliberately keeps these from
# ever being the candidate — so read the full table instead.
tuxedo_version() {
    apt-cache madison "$1" 2>/dev/null \
        | awk -v site="$TUXEDO_SITE" 'index($0, site) { print $3; exit }'
}

remove_tuxedo_repo() {
    sudo rm -f "$TUXEDO_LIST" "$TUXEDO_PREFS"
    sudo apt-get update -qq || true
}

# Adds the archive *already pinned* — the preferences file is written before the
# first `apt-get update` that can see the archive, so there is never a window in
# which its 1.6.8 PipeWire or Mesa 26 is a valid candidate.
setup_tuxedo_repo() {
    # Called from two places now; adding it twice is harmless but the second
    # caller should not pay for another two `apt-get update` runs.
    if [[ -f "$TUXEDO_LIST" && -f "$TUXEDO_PREFS" ]]; then
        return 0
    fi

    (( DO_TUXEDO_REPO )) \
        || die "this needs the TUXEDO ubuntu-plasma archive, but --no-tuxedo-repo
             was given. Install the missing packages yourself, or drop the flag."

    local codename=""
    [[ -r /etc/os-release ]] && codename="$(. /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-}")"
    [[ "$codename" == "noble" ]] \
        || die "the TUXEDO archive is only wired up for noble (this is
             '${codename:-unknown}'). Install libwireplumber-0.5-dev and
             libwayland-dev >= $WAYLAND_MIN yourself, or pass --no-tuxedo-repo."

    info "adding TUXEDO ubuntu-plasma archive (needs root)"
    sudo apt-get install -y gnupg ca-certificates curl

    if [[ ! -f "$TUXEDO_KEYRING" ]]; then
        # Deliberately not `local`: the EXIT trap is evaluated at shell exit, by
        # which point a function-local would be out of scope. `die` exits rather
        # than returning, so EXIT is the only hook that covers the failure path.
        WP_TMPKEY="$(mktemp)"
        WP_TMPGPG="$(mktemp -d)"
        chmod 700 "$WP_TMPGPG"
        trap 'rm -rf "${WP_TMPKEY:-}" "${WP_TMPGPG:-}"' EXIT
        curl --proto '=https' --tlsv1.2 -fsSL "$TUXEDO_KEY_URL" -o "$WP_TMPKEY"
        # Fail closed if the published key is not the fingerprint we pinned.
        # --homedir keeps this off the user's keyring and trustdb entirely; a
        # plain `gpg --show-keys` dies outright if ~/.gnupg is not writable.
        gpg --homedir "$WP_TMPGPG" --show-keys --with-colons "$WP_TMPKEY" 2>/dev/null \
            | awk -F: '$1 == "fpr" { print $10 }' | grep -qx "$TUXEDO_KEY_FPR" \
            || die "key at $TUXEDO_KEY_URL is not $TUXEDO_KEY_FPR — refusing to trust it"
        sudo gpg --batch --yes --dearmor -o "$TUXEDO_KEYRING" "$WP_TMPKEY"
        rm -rf "$WP_TMPKEY" "$WP_TMPGPG"
        trap - EXIT
        info "Installed TUXEDO signing key $TUXEDO_KEY_FPR"
    fi

    # Snapshot against freshly updated indexes so a coincidental archive refresh
    # is not mistaken for the pin failing.
    sudo apt-get update
    local before after
    before="$(tuxedo_guard_snapshot)"

    # Pin by site hostname: `release o=` would be wrong here, because both TUXEDO
    # archives declare the same Origin (TUXEDO Computers) and only this one should
    # be constrained. Priority 100 lands in the "install unless a version from
    # another distribution is available" band, which default-denies the 186
    # contested packages while still allowing the three that exist nowhere else.
    printf 'Package: *\nPin: origin "%s"\nPin-Priority: 100\n' "$TUXEDO_SITE" \
        | sudo tee "$TUXEDO_PREFS" >/dev/null
    printf 'deb [signed-by=%s] https://%s/ubuntu-plasma noble main\n' \
        "$TUXEDO_KEYRING" "$TUXEDO_SITE" | sudo tee "$TUXEDO_LIST" >/dev/null

    sudo apt-get update
    after="$(tuxedo_guard_snapshot)"

    if [[ "$before" != "$after" ]]; then
        warn "pin did not hold — these candidates moved:"
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
        remove_tuxedo_repo
        die "removed $TUXEDO_LIST and $TUXEDO_PREFS again; nothing was installed"
    fi
    info "Pin verified: candidates for ${TUXEDO_GUARD_PKGS[*]} unchanged"
}

# Decides between "already fine", "the archives already have it" (26.04+, or a
# box set up earlier) and "add the pinned archive".
ensure_wireplumber_05() {
    if have_wireplumber_05; then
        info "wireplumber-0.5 already visible to pkg-config; leaving apt sources alone"
    elif [[ -n "$(apt_candidate libwireplumber-0.5-dev)" ]]; then
        info "libwireplumber-0.5-dev is in the configured archives; no extra source needed"
    elif (( DO_TUXEDO_REPO )); then
        setup_tuxedo_repo
    else
        warn "no libwireplumber-0.5-dev candidate and --no-tuxedo-repo given;
             meson.build:91 will fail on wireplumber-0.5"
    fi
}

# ── libwayland >= 1.23 ───────────────────────────────────────────────────────

# Gap 6. meson.build:66 is a bare dependency('wayland-client') with no version
# floor, so configure passes on noble's 1.22 and the build only dies ~630 targets
# in, at src/wayland/virtual_keyboard_service.cpp:95. Checked up front instead.
ensure_wayland_123() {
    local have cand tux
    have="$(pkg-config --modversion wayland-client 2>/dev/null || true)"
    if [[ -n "$have" ]] && version_ge "$have" "$WAYLAND_MIN"; then
        info "wayland-client $have already >= $WAYLAND_MIN"
        return 0
    fi

    # 26.04 and later ship 1.23+ natively; nothing to do, the normal apt step
    # below installs libwayland-dev like any other package.
    cand="$(apt_candidate libwayland-dev)"
    if [[ -n "$cand" ]] && version_ge "${cand%%-*}" "$WAYLAND_MIN"; then
        info "libwayland-dev $cand is in the configured archives; installing with the rest"
        return 0
    fi

    if ! (( DO_TUXEDO_REPO )); then
        warn "wayland-client is ${have:-absent} and --no-tuxedo-repo was given;
             the build will fail at virtual_keyboard_service.cpp:95 on
             wl_proxy_get_display (needs >= $WAYLAND_MIN)"
        return 0
    fi

    setup_tuxedo_repo

    tux="$(tuxedo_version libwayland-dev)"
    [[ -n "$tux" ]] \
        || die "the TUXEDO archive offers no libwayland-dev; cannot reach
             wayland >= $WAYLAND_MIN"
    version_ge "${tux%%-*}" "$WAYLAND_MIN" \
        || die "TUXEDO's libwayland-dev is $tux, still below $WAYLAND_MIN"

    # Must be by exact version: the pin keeps these below noble's 1.22, so a bare
    # `apt-get install libwayland-dev` would happily reinstall the old one. The
    # six move in lockstep (each Depends: (= ${binary:Version})), so they go
    # together or not at all.
    info "Installing libwayland $tux from the pinned TUXEDO archive (needs root)"
    sudo apt-get install -y "${WAYLAND_PKGS[@]/%/=$tux}"

    have="$(pkg-config --modversion wayland-client 2>/dev/null || true)"
    version_ge "${have:-0}" "$WAYLAND_MIN" \
        || die "libwayland is still ${have:-absent} after installing $tux"
    info "wayland-client is now $have"
}

# ── 1. System packages ───────────────────────────────────────────────────────

PACKAGES=(
    meson ninja-build pkg-config curl
    "gcc-$GCC_SUFFIX" "g++-$GCC_SUFFIX"
    libwayland-dev wayland-protocols
    libegl-dev libgles-dev
    libfreetype-dev libfontconfig-dev
    libcairo2-dev libpango1.0-dev libharfbuzz-dev
    libxkbcommon-dev libglib2.0-dev
    libsecret-1-dev libsodium-dev
    libsdbus-c++-dev libpipewire-0.3-dev libwireplumber-0.5-dev
    libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev
    libcurl4-openssl-dev libwebp-dev libjxl-dev libsndfile1-dev librsvg2-dev
    libqalculate-dev libxml2-dev
    libmd4c-dev libtomlplusplus-dev libical-dev
    nlohmann-json3-dev
    libjemalloc-dev
)
# Deliberately not installed: libstb-dev. Its stb_image_write.h would do, but
# the package is too old for stb_image_resize2.h, and the vendored copy below
# supplies both halves consistently.

if (( DO_APT )); then
    if needs_noble_workarounds; then
        ensure_wireplumber_05
        ensure_wayland_123
    else
        info "Ubuntu $(ubuntu_version) ships wireplumber-0.5 and libwayland >= $WAYLAND_MIN; skipping the noble workarounds"
    fi

    info "Checking package availability"
    available=() missing=()
    for pkg in "${PACKAGES[@]}"; do
        if [[ -n "$(apt_candidate "$pkg")" ]]; then
            available+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} )); then
        for pkg in "${missing[@]}"; do
            case "$pkg" in
                libwireplumber-0.5-dev)
                    # Not substitutable: meson.build:91 requires wireplumber-0.5
                    # outright, so libwireplumber-0.4-dev would install and then
                    # be ignored. Stopping here beats failing at configure time.
                    die "no candidate for $pkg. Noble ships only 0.4.17 and
             libwireplumber-0.4-dev will not satisfy meson.build:91. See the
             WirePlumber section of the hypr-config README."
                    ;;
            esac
            warn "no candidate for $pkg — skipping; configure may fail on it"
        done
    fi

    info "Installing system packages (needs root):"
    printf '    sudo apt-get install -y %s\n' "${available[*]}"
    sudo apt-get install -y "${available[@]}"
else
    info "Skipping apt (--no-apt)"
fi

command -v "gcc-$GCC_SUFFIX" >/dev/null || die "gcc-$GCC_SUFFIX not found; install it or drop --no-apt"
command -v "g++-$GCC_SUFFIX" >/dev/null || die "g++-$GCC_SUFFIX not found; install it or drop --no-apt"

# ── 2. just >= 1.40.0 ────────────────────────────────────────────────────────

# Pick the first `just` on PATH that is new enough, preferring ~/.local/bin
# (which on a default Ubuntu PATH is *behind* /usr/bin, so an old apt-installed
# just would otherwise win).
find_just() {
    local cand
    for cand in "$HOME/.local/bin/just" $(type -a -P just 2>/dev/null || true); do
        [[ -x "$cand" ]] || continue
        local ver
        ver="$("$cand" --version 2>/dev/null | awk '{print $2}')" || continue
        if version_ge "${ver:-0}" "$JUST_MIN"; then
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

if JUST="$(find_just)"; then
    info "Using just: $JUST ($("$JUST" --version))"
else
    info "No just >= $JUST_MIN found; installing upstream into ~/.local/bin"
    mkdir -p "$HOME/.local/bin"
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
        | bash -s -- --to "$HOME/.local/bin"
    JUST="$(find_just)" || die "just install did not produce a usable binary"
    info "Installed $("$JUST" --version)"

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) warn "~/.local/bin is not on your PATH; add this to ~/.zshrc:
             export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
    if command -v just >/dev/null && [[ "$(command -v just)" != "$JUST" ]]; then
        warn "\`just\` still resolves to $(command -v just) ($(just --version 2>&1 | head -n1));
             this script uses $JUST explicitly, but your own \`just\` calls will not."
    fi
fi

# ── 3. stb_image_resize2.h ───────────────────────────────────────────────────

STB_CPPFLAGS=()
if [[ -f /usr/include/stb/stb_image_resize2.h || -f /usr/local/include/stb/stb_image_resize2.h ]]; then
    info "System stb_image_resize2.h found; not vendoring"
else
    if [[ ! -f "$VENDOR_DIR/stb/stb_image_resize2.h" ]]; then
        info "Vendoring stb_image_resize2.h into third_party/stb-compat/"
        mkdir -p "$VENDOR_DIR/stb"
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        curl --proto '=https' --tlsv1.2 -sSfL "$STB_URL" -o "$tmp"
        grep -q 'stbir_resize' "$tmp" || die "downloaded stb header looks wrong"
        mv "$tmp" "$VENDOR_DIR/stb/stb_image_resize2.h"
        trap - EXIT
    else
        info "Vendored stb_image_resize2.h already present"
    fi
    # meson.build also checks for stb/stb_image_write.h. libstb-dev provides it,
    # but keep the vendored dir self-sufficient so the build does not depend on
    # which halves the distro happens to ship.
    if [[ ! -f "$VENDOR_DIR/stb/stb_image_write.h" && ! -f /usr/include/stb/stb_image_write.h ]]; then
        info "Vendoring stb_image_write.h as well"
        curl --proto '=https' --tlsv1.2 -sSfL \
            "https://raw.githubusercontent.com/nothings/stb/$STB_COMMIT/stb_image_write.h" \
            -o "$VENDOR_DIR/stb/stb_image_write.h"
    fi
    STB_CPPFLAGS=("-I$VENDOR_DIR")
fi

# ── 4. Configure and build ───────────────────────────────────────────────────

export CC="gcc-$GCC_SUFFIX"
export CXX="g++-$GCC_SUFFIX"
export CPPFLAGS="${STB_CPPFLAGS[*]:-}${CPPFLAGS:+ $CPPFLAGS}"

BUILD_DIR="$REPO_DIR/build-$MODE"

# Meson caches compiler detection and bakes CPPFLAGS in at setup time, so a
# build dir configured with different compilers or include paths has to go.
if [[ -d "$BUILD_DIR" ]]; then
    stale=0
    log="$BUILD_DIR/meson-logs/meson-log.txt"
    if [[ -f "$log" ]]; then
        grep -q "C compiler for the host machine: $CC " "$log" || stale=1
        grep -q "C++ compiler for the host machine: $CXX " "$log" || stale=1
    else
        stale=1
    fi
    if (( stale )); then
        # meson-logs/install-log.txt is the manifest `just uninstall` reads.
        # Deleting the build dir orphans any files a previous `just install`
        # put on the system, so say so rather than silently discarding it.
        if [[ -f "$BUILD_DIR/meson-logs/install-log.txt" ]]; then
            warn "$BUILD_DIR records a previous install:
             $(awk 'NR==3 {print $0}' "$BUILD_DIR/meson-logs/install-log.txt")...
             Deleting it loses the manifest \`just uninstall $MODE\` needs.
             Run \`just uninstall $MODE\` first if you want those files removed."
        fi
        info "Removing stale $BUILD_DIR (configured with different compilers)"
        rm -rf "$BUILD_DIR"
    fi
fi

info "Configuring ($MODE, prefix $PREFIX)"
info "  CC=$CC CXX=$CXX CPPFLAGS=${CPPFLAGS:-<empty>}"
cd "$REPO_DIR"
"$JUST" configure "$MODE" "$PREFIX"

info "Building ($MODE) — this takes a while"
"$JUST" build "$MODE"

if (( DO_INSTALL )); then
    info "Installing into $PREFIX"
    "$JUST" install "$MODE"
    case ":$PATH:" in
        *":$PREFIX/bin:"*) ;;
        *) warn "$PREFIX/bin is not on your PATH" ;;
    esac
else
    info "Not installing. To install into $PREFIX:"
    printf '    %s install %s\n' "$JUST" "$MODE"
fi

info "Done. Binary: $BUILD_DIR/noctalia"
