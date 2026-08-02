#!/usr/bin/env bash
#
# install-noctalia.sh — build Noctalia on Ubuntu 24.04 LTS "noble".
#
# The README's Debian/Ubuntu instructions do not work as written on 24.04.
# This script works around the four gaps:
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
#
# Usage:
#   ./install-noctalia.sh                 # apt deps, configure, build (release)
#   ./install-noctalia.sh --no-apt        # skip apt; everything else
#   ./install-noctalia.sh --install       # also `just install` into --prefix
#   ./install-noctalia.sh --mode debug    # debug build instead of release
#   ./install-noctalia.sh --prefix /usr/local
#
# The only step needing root is the apt install. It is printed before it runs,
# and can be skipped with --no-apt if you prefer to run it yourself.

set -euo pipefail

MODE=release
PREFIX="$HOME/.local"
DO_APT=1
DO_INSTALL=0

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$REPO_DIR/third_party/stb-compat"

# stb has no releases; pinned to the last commit touching this header.
STB_COMMIT=904aa67e1e2d1dec92959df63e700b166d5c1022
STB_URL="https://raw.githubusercontent.com/nothings/stb/$STB_COMMIT/stb_image_resize2.h"

JUST_MIN=1.40.0
GCC_SUFFIX=14

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
    info "Checking package availability"
    available=() missing=()
    for pkg in "${PACKAGES[@]}"; do
        if [[ -n "$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]]; then
            available+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} )); then
        # Stock noble ships wireplumber 0.4; the 0.5 dev package comes from
        # newer PPAs (TUXEDO OS has it). Substitute rather than fail.
        for pkg in "${missing[@]}"; do
            case "$pkg" in
                libwireplumber-0.5-dev)
                    if [[ -n "$(apt-cache policy libwireplumber-0.4-dev 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" {print $2}')" ]]; then
                        warn "$pkg unavailable; using libwireplumber-0.4-dev instead"
                        available+=(libwireplumber-0.4-dev)
                        continue
                    fi
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
