#!/usr/bin/env bash
#
# Install the Fairlight capture fix for DaVinci Resolve on PipeWire.
#
# Everything lands in $HOME. No root, no changes to PipeWire, ALSA, or any
# other application. Resolve keeps launching the normal way.
#
#   ./install.sh              build and install
#   ./install.sh --uninstall  remove it again
#
set -euo pipefail

LIBDIR="$HOME/.local/lib/resolve-shim"
BINDIR="$HOME/.local/bin"
APPDIR="$HOME/.local/share/applications"
SHIM="$LIBDIR/resolve-alsa-shim.so"
DESKTOP="com.blackmagicdesign.resolve.desktop"
SRC_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src/resolve-alsa-shim.c"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    echo "Removing the Fairlight capture fix..."
    rm -f "$BINDIR/resolve" "$APPDIR/$DESKTOP"
    rm -rf "$LIBDIR"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPDIR" 2>/dev/null || true
    ok "removed. Resolve will use the stock launcher again."
    exit 0
fi

echo "DaVinci Resolve Linux fixes — glib startup crash + Fairlight silent capture"
echo

# ---- checks -----------------------------------------------------------------
[ -x /opt/resolve/bin/resolve ] || die "DaVinci Resolve not found at /opt/resolve/bin/resolve"
command -v gcc >/dev/null || die "gcc not found. Install it:  sudo apt install build-essential"
ok "Resolve found at /opt/resolve/bin/resolve"

if command -v pipewire >/dev/null; then
    ok "PipeWire $(pipewire --version 2>&1 | awk '/libpipewire/{print $NF; exit}')"
else
    warn "PipeWire not detected. This fix targets PipeWire's ALSA plugin;"
    warn "on plain ALSA or PulseAudio it should be harmless but is untested."
fi

# ---- build ------------------------------------------------------------------
SRC="${SHIM_SRC:-$SRC_DEFAULT}"
[ -r "$SRC" ] || die "source not found: $SRC"
mkdir -p "$LIBDIR" "$BINDIR" "$APPDIR"
cp -f "$SRC" "$LIBDIR/resolve-alsa-shim.c"
gcc -shared -fPIC -O2 -Wall -o "$SHIM" "$LIBDIR/resolve-alsa-shim.c" -ldl \
    || die "build failed"
ok "built $SHIM"

# ---- launcher ---------------------------------------------------------------
# $HOME/.local/bin precedes /usr/local/bin on a default Ubuntu PATH, and a
# desktop entry in $HOME overrides the one in /usr/share/applications. Both of
# those system files get overwritten by every Resolve installer run; these do
# not, which is why the fix is installed here rather than there.
cat > "$BINDIR/resolve" <<'LAUNCHER'
#!/bin/bash
# DaVinci Resolve, with two workarounds preloaded.
# https://github.com/peternavr/davinciresolve
#
#  1. glib mismatch — Resolve crashes before its window appears with
#       symbol lookup error: libgio-2.0.so.0: undefined symbol: g_source_set_static_name
#     Resolve bundles glib 2.68 and wins for it via DT_RPATH, but the system
#     libgio still gets pulled in through system dependencies, and the two
#     versions can't be mixed. LD_PRELOAD outranks DT_RPATH; LD_LIBRARY_PATH
#     does not, which is why setting that alone doesn't help.
#
#  2. Fairlight records digital silence — PipeWire's ALSA plugin never raises
#     POLLIN via snd_pcm_poll_descriptors_revents(), and Fairlight gates
#     snd_pcm_readi on exactly that.
#
# Both are no-ops when the corresponding bug isn't present.
export LD_LIBRARY_PATH=/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/opt/resolve/libs

PRELOAD=""
add_preload() { [ -r "$1" ] && PRELOAD="${PRELOAD:+$PRELOAD:}$1"; }

# ---- 1. system glib, but ONLY if it is newer than Resolve's bundled copy -----
# Forcing the system glib on a distro whose glib is OLDER than the bundled 2.68
# would break a Resolve that works fine, so preload only in the one direction
# that actually causes the crash.
_glibdir=""
for _d in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    [ -e "$_d/libglib-2.0.so.0" ] && { _glibdir="$_d"; break; }
done
_bundled_glib=/opt/resolve/libs/libglib-2.0.so.0

if [ -n "$_glibdir" ] && [ -e "$_bundled_glib" ]; then
    _sysv=$(basename "$(readlink -f "$_glibdir/libglib-2.0.so.0")"); _sysv=${_sysv#libglib-2.0.so.}
    _bunv=$(basename "$(readlink -f "$_bundled_glib")");             _bunv=${_bunv#libglib-2.0.so.}
    if [ "$_sysv" != "$_bunv" ] &&
       [ "$(printf '%s\n%s\n' "$_sysv" "$_bunv" | sort -V | tail -1)" = "$_sysv" ]; then
        for _lib in libglib-2.0.so.0 libgobject-2.0.so.0 libgmodule-2.0.so.0 libgio-2.0.so.0; do
            add_preload "$_glibdir/$_lib"
        done
    fi
fi

# ---- 2. Fairlight ALSA capture fix ------------------------------------------
add_preload "$HOME/.local/lib/resolve-shim/resolve-alsa-shim.so"

[ -n "$PRELOAD" ] && export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$PRELOAD"

exec /opt/resolve/bin/resolve "$@"
LAUNCHER
chmod 755 "$BINDIR/resolve"
ok "installed launcher $BINDIR/resolve"

# ---- desktop entry ----------------------------------------------------------
SYS_DESKTOP="/usr/share/applications/$DESKTOP"
if [ -r "$SYS_DESKTOP" ]; then
    sed "s|^Exec=/opt/resolve/bin/resolve|Exec=$BINDIR/resolve|" "$SYS_DESKTOP" > "$APPDIR/$DESKTOP"
    command -v update-desktop-database >/dev/null && update-desktop-database "$APPDIR" 2>/dev/null || true
    ok "menu and dock entry now use the fixed launcher"
else
    warn "no system desktop entry found; launch with '$BINDIR/resolve'"
fi

# ---- PATH sanity ------------------------------------------------------------
case ":$PATH:" in
    *":$BINDIR:"*) ok "$BINDIR is on your PATH" ;;
    *) warn "$BINDIR is NOT on your PATH — add it, or launch from the menu" ;;
esac

echo
echo "Done. Launch Resolve normally, open Fairlight, arm a track."
echo "The input meter should move."
echo
echo "To verify the fix is doing work:"
echo "    RESOLVE_ALSA_SHIM_LOG=1 resolve"
echo "    grep 'forcing POLLIN' /tmp/resolve-alsa-shim.log"
echo
echo "To remove:  ./install.sh --uninstall"
