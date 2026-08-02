#!/usr/bin/env bash
#
# Do I have THIS bug?
#
# Distinguishes the Fairlight/PipeWire silent-capture bug from the other
# reasons Resolve might record silence (dead mic, wrong routing, DeckLink,
# device not found). Read-only — changes nothing.
#
set -uo pipefail

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

echo
echo "DaVinci Resolve on Linux — startup and capture diagnostic"
echo "=========================================================="
echo

verdict_bug=0
verdict_blocked=0
verdict_glib=0

# ---- 1. Resolve present, and which version -----------------------------------
echo "[1] DaVinci Resolve"
if [ -x /opt/resolve/bin/resolve ]; then
    ver="$(cat /opt/resolve/docs/*version* 2>/dev/null | head -1)"
    [ -z "$ver" ] && ver="$(strings -a /opt/resolve/bin/resolve 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]{4}$' | head -1)"
    pass "installed${ver:+ — version $ver}"
else
    fail "not found at /opt/resolve/bin/resolve"
    echo; echo "Nothing to diagnose."; exit 1
fi

FL=/opt/resolve/libs/libFairlightPage.so
if [ -r "$FL" ]; then
    pass "audio engine: $FL"
else
    fail "libFairlightPage.so missing — unexpected install layout"
    exit 1
fi
echo

# ---- 2. Does Resolve even start? (bundled vs system glib) ---------------------
# Checked before the audio path, because this one stops Resolve launching at all.
echo "[2] Startup: bundled vs system glib"
_glibdir=""
for _d in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    [ -e "$_d/libglib-2.0.so.0" ] && { _glibdir="$_d"; break; }
done
_bundled_glib=/opt/resolve/libs/libglib-2.0.so.0

if [ -z "$_glibdir" ] || [ ! -e "$_bundled_glib" ]; then
    pass "no bundled/system glib conflict possible here"
else
    _sysv=$(basename "$(readlink -f "$_glibdir/libglib-2.0.so.0")"); _sysv=${_sysv#libglib-2.0.so.}
    _bunv=$(basename "$(readlink -f "$_bundled_glib")");             _bunv=${_bunv#libglib-2.0.so.}
    info "system glib $_sysv, Resolve bundles $_bunv"
    if [ "$_sysv" != "$_bunv" ] &&
       [ "$(printf '%s\n%s\n' "$_sysv" "$_bunv" | sort -V | tail -1)" = "$_sysv" ]; then
        fail "system glib is newer than Resolve's bundled copy"
        info "Resolve may crash at startup with:"
        info "  undefined symbol: g_source_set_static_name"
        info "The launcher installed by ./install.sh works around this."
        verdict_glib=1
    else
        pass "no version skew that would break startup"
    fi
fi
echo

# ---- 3. The two binary fingerprints of this bug -------------------------------
echo "[3] Resolve's ALSA capture code path"
if command -v nm >/dev/null; then
    # Match in-shell rather than through a pipe. `grep -q` exits on first hit,
    # SIGPIPEs whatever is feeding it, and under `set -o pipefail` that turns
    # a successful match into a non-zero status — silently inverting the test.
    # This library has 65k symbols, so it happens every time.
    SYMS="$(nm -D "$FL" 2>/dev/null || true)"

    if [ -z "$SYMS" ]; then
        warn "could not read symbols from libFairlightPage.so — skipping"
    else
    if case "$SYMS" in *snd_pcm_readi*) true;; *) false;; esac; then
        pass "snd_pcm_readi is imported — this is the only capture read path"
    else
        warn "snd_pcm_readi NOT imported — your build reads input some other way"
        info "this fix may not apply; please open an issue with your version"
    fi

    if case "$SYMS" in *snd_pcm_start*) true;; *) false;; esac; then
        pass "snd_pcm_start IS imported — bug 2 (unstarted stream) absent in this build"
    else
        fail "snd_pcm_start is NOT imported anywhere"
        info "Fairlight never starts a capture stream. This is bug 2, confirmed."
        verdict_bug=1
    fi
    fi
else
    warn "'nm' not available (install binutils) — skipping binary checks"
fi
echo

# ---- 4. Is ALSA's default device a PipeWire plugin? ---------------------------
echo "[4] What Resolve gets when it opens ALSA 'default'"
conf=$(grep -rl 'type *pipewire' /etc/alsa/conf.d/ /usr/share/alsa/alsa.conf.d/ 2>/dev/null | head -1)
if [ -n "$conf" ]; then
    pass "ALSA 'default' is routed to PipeWire"
    info "via $conf"
    verdict_bug=1
elif grep -rq 'type *pulse' /etc/alsa/conf.d/ 2>/dev/null; then
    warn "ALSA 'default' is routed to PulseAudio"
    info "same class of bug is plausible but untested — the fix is safe to try"
else
    warn "ALSA 'default' is not an obvious PipeWire/Pulse plugin"
    info "if Resolve opens a raw hw: device, this bug likely does not apply"
fi

if command -v pipewire >/dev/null; then
    pass "PipeWire $(pipewire --version 2>&1 | awk '/libpipewire/{print $NF; exit}') running"
fi
echo

# ---- 5. Rule out the boring causes -------------------------------------------
echo "[5] Ruling out the other causes of silence"
if command -v pw-record >/dev/null || command -v arecord >/dev/null; then
    tmp=$(mktemp /tmp/fldiag-XXXXXX.wav)
    echo "    recording 3 seconds from your default input — make some noise now..."
    if command -v pw-record >/dev/null; then
        timeout 4 pw-record --rate 48000 --channels 1 --format s16 "$tmp" >/dev/null 2>&1 &
        wait $! 2>/dev/null
    else
        timeout 4 arecord -f S16_LE -r 48000 -c 1 "$tmp" >/dev/null 2>&1
    fi

    nz=$(python3 - "$tmp" <<'PY' 2>/dev/null
import sys,wave
try:
    w=wave.open(sys.argv[1],'rb'); raw=w.readframes(w.getnframes())
except Exception: print(-1); raise SystemExit
sw=w.getsampwidth()
peak=max((abs(int.from_bytes(raw[i:i+sw],'little',signed=True)) for i in range(0,len(raw)-sw+1,sw)), default=0)
print(peak)
PY
)
    rm -f "$tmp"
    if [ "${nz:--1}" = "-1" ]; then
        warn "could not analyse the test recording (python3 missing?) — skipping"
    elif [ "${nz:-0}" -gt 200 ]; then
        pass "your microphone works outside Resolve (peak $nz)"
    else
        fail "your microphone captured (near) silence outside Resolve too"
        info "Fix your input first — this shim cannot help with a dead mic."
        verdict_blocked=1
    fi
else
    warn "neither pw-record nor arecord available — skipping the mic test"
fi
echo

# ---- verdict ------------------------------------------------------------------
echo "==================================="
if [ "$verdict_glib" = "1" ]; then
    echo "VERDICT: Resolve will likely not start at all (glib version skew)."
    echo
    echo "         Fix that first:   ./install.sh"
    echo "         Then launch Resolve and re-run this script to check audio."
elif [ "$verdict_blocked" = "1" ]; then
    echo "VERDICT: your input is silent at the OS level."
    echo "         This is not the Fairlight bug. Fix the mic/routing first,"
    echo "         then re-run this script."
elif [ "$verdict_bug" = "1" ]; then
    echo "VERDICT: you have this bug."
    echo
    echo "         Install the fix:   ./install.sh"
    echo
    echo "         Then launch Resolve, open Fairlight, arm a track."
    echo "         The input meter should move."
else
    echo "VERDICT: inconclusive — the fingerprints don't clearly match."
    echo
    echo "         The fix is a no-op when the bug isn't present, so trying it"
    echo "         is safe. To see whether it engages:"
    echo "             ./install.sh"
    echo "             RESOLVE_ALSA_SHIM_LOG=1 resolve"
    echo "             grep 'forcing POLLIN' /tmp/resolve-alsa-shim.log"
    echo
    echo "         Lines there = the bug was real and is now being worked around."
fi
echo
