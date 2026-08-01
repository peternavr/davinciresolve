# DaVinci Resolve — Fairlight records silence on PipeWire

**Resolve's Fairlight page records bit-exact digital zero on Linux while every other application's audio works fine.** This repo explains exactly why, and fixes it.

The cause is not a setting, not your microphone, not track arming, and not your PipeWire config. It is a genuine incompatibility between how Fairlight polls ALSA for input and how PipeWire's ALSA plugin reports readiness.

```bash
git clone https://github.com/peternavr/davinciresolve
cd davinciresolve && ./install.sh
```

No root. Nothing outside `$HOME`. PipeWire, ALSA, and every other app are left untouched. Resolve keeps launching the normal way.

---

## Symptoms

- Voiceover / Fairlight takes are silent — not quiet, **bit-exact zero** on every sample.
- The Fairlight **input meter never moves**, no matter which input you patch.
- Playback, monitoring, scrubbing, and rendered audio all work perfectly.
- `arecord`, `pw-record`, Audacity, OBS, browsers, and everything else record fine.
- Resolve's own logs show **no audio errors at all**. The engine isn't failing — it just never reads.

If that's you, run `./diagnose.sh`. It confirms the bug in about 30 seconds.

---

## Why it happens

Fairlight's record loop is `ALSAPlayandCaptureLoop` in `/opt/resolve/libs/libFairlightPage.so`. Each iteration:

```c
snd_pcm_avail(capture);                              /* how much input is waiting */
poll(fds);
snd_pcm_poll_descriptors_revents(capture, &revents);
if (revents & POLLIN)                                /* ← THE GATE */
    snd_pcm_readi(capture, buf, frames);             /* ← the ONLY capture read in the product */
```

`snd_pcm_readi` is Fairlight's only path to input audio. It imports no mmap capture functions at all — that one call is the whole recording feature. So when the gate never opens, nothing is ever ingested.

**PipeWire's ALSA plugin never raises `POLLIN` through `snd_pcm_poll_descriptors_revents()` on a capture handle.** Measured over a 90-second run: **11,070 consecutive calls, every one returning `revents = 0x0`**, while `snd_pcm_avail()` on the very same handle simultaneously reported a **completely full 4096-frame buffer of real microphone audio**.

Fairlight sat next to a full bucket of audio and never picked it up. `snd_pcm_readi` call count: **zero**.

Fairlight's own internal logger says it in one line:

```
revents = 0:0   initalAvailablePlay 4096   availplay 133   availcap 4096
                                                           ^^^^^^^^^^^^ pinned full, forever
```

### Why playback still worked — and why this was so hard to diagnose

The write path is driven by *available space* (`availplay`), not by revents. So output was completely unaffected while input was stone dead. Every symptom pointed at configuration: audio demonstrably worked on the machine, worked in every other app, and Resolve itself reported no errors. There is nothing in the UI that can fix it, and no combination of PipeWire settings that changes it.

### The second, smaller bug

**Fairlight never calls `snd_pcm_start()`.** The symbol isn't imported anywhere in the product. The capture stream is opened and prepared but never started, so it sits in `PREPARED` producing nothing even if the gate did open. Both bugs are fixed together — fixing either one alone still gives you silence.

### Whose bug is it?

Both sides are defensible, which is why neither has fixed it:

- **Resolve** polls `revents` and ignores a non-empty `snd_pcm_avail()`. That's a legal but brittle read of the ALSA API — and not calling `snd_pcm_start()` on a capture stream is simply a bug.
- **PipeWire's ALSA plugin** doesn't signal `POLLIN` for a capture stream that was never started. Also defensible.

Neither is under your control, so the fix goes in between them.

---

## What the fix actually does

An `LD_PRELOAD` shim that interposes two of libasound's public symbols, loaded **only** inside Resolve:

1. **`snd_pcm_poll_descriptors_revents()`** — if the handle is a capture stream, `POLLIN` is clear, and `snd_pcm_avail_update()` reports at least one full period genuinely ready, set `POLLIN`. **It never invents readiness that isn't there.** If there's no audio, it reports no audio.
2. **Stream start** — any capture PCM found in `PREPARED` gets `snd_pcm_start()`; any found in `XRUN` gets `prepare` + `start`.

Everything else is straight pass-through. That's it — about 60 lines of actual logic in [`src/resolve-alsa-shim.c`](src/resolve-alsa-shim.c).

### Before / after, in Fairlight's own numbers

| | `availcap` | `snd_pcm_readi` calls |
|---|---|---|
| before | 4096 — stuck full, never drained | **0** |
| after | 21–191 — actively drained | **~7,000 per 48 s**, `got=455` every time |

---

## Will this fix *my* Resolve?

### What layer this operates at

The fix sits at the **ALSA client library boundary inside Resolve's process** — it hooks `libasound`, not Resolve and not PipeWire. That has three consequences worth understanding:

- **It is Resolve-version-independent.** Nothing is patched inside any Resolve binary, no offsets or symbol addresses are hardcoded, and no Resolve file is modified. A Resolve upgrade cannot break it.
- **It is self-cancelling.** The shim only sets `POLLIN` when a capture handle genuinely has a period of data waiting. On a system that doesn't have this bug, that condition is already true and the shim does nothing. **Installing it on a working setup is a no-op**, not a risk.
- **It is scoped to Resolve alone.** It is preloaded by one launcher script. No other process ever loads it.

### Confirmed affected

| Component | Version tested |
|---|---|
| DaVinci Resolve Studio | **21.0.3** (build `21.0.30007`) — broken |
| DaVinci Resolve Studio | **21.0.2** — broken, identical behaviour |
| Ubuntu | 26.04 LTS |
| Kernel | 7.0.0-28-generic |
| PipeWire | 1.6.2 |
| ALSA (libasound2) | 1.2.15.3 |
| gcc | 15.2.0 |

### Expected to be affected

The gating code lives in `ALSAPlayandCaptureLoop`, which has been Fairlight's Linux capture path for many releases, and the missing `snd_pcm_start` import is longstanding. **Any Resolve version whose `libFairlightPage.so` shows this pattern is affected.** Check yours in one command:

```bash
# Fairlight's only capture read. If this prints a line, that lone snd_pcm_readi
# behind a revents gate is your record path.
nm -D /opt/resolve/libs/libFairlightPage.so | grep -w snd_pcm_readi

# If this prints NOTHING, Fairlight never starts capture streams — bug 2 confirmed.
nm -D /opt/resolve/libs/libFairlightPage.so | grep -w snd_pcm_start
```

This applies equally to Resolve **Studio and the free version** — the audio engine is the same library.

### It should also fix these

Any ALSA-client layer that behaves the same way on capture. The shim doesn't know or care what's behind `default`:

- **PulseAudio's ALSA plugin** (`pcm_pulse`) — same class of symptom, untested here.
- **dmix / dsnoop / plug chains** where the slave never signals POLLIN.

### It will *not* fix

Be clear-eyed about scope. This fixes exactly one failure mode. It will not help if:

- **The input meter moves but takes are still silent** — that's routing, arming, or bus configuration, not this bug.
- **You use a DeckLink / Blackmagic capture card for audio.** That path doesn't go through ALSA at all.
- **Resolve doesn't see your device.** This bug is *downstream* of device selection; Fairlight enumerates and opens the device perfectly, then declines to read from it.
- **Your microphone genuinely isn't producing audio.** Confirm first: `pw-record -` or `arecord -f cd -d 3 /tmp/t.wav && aplay /tmp/t.wav`.

`./diagnose.sh` distinguishes these for you.

---

## Install

```bash
./install.sh
```

That builds the shim and installs three things, all in `$HOME`:

| Path | What |
|---|---|
| `~/.local/lib/resolve-shim/resolve-alsa-shim.so` | the shim |
| `~/.local/bin/resolve` | launcher that preloads it |
| `~/.local/share/applications/com.blackmagicdesign.resolve.desktop` | menu / dock entry |

Then launch Resolve normally — dock, menu, or `resolve` in a terminal.

**Why `$HOME` and not `/usr/local/bin`?** Both `/usr/local/bin/resolve` and `/usr/share/applications/com.blackmagicdesign.resolve.desktop` are overwritten by every Resolve installer run. `~/.local/bin` precedes `/usr/local/bin` on a default Ubuntu `PATH`, and a desktop entry in `~/.local/share/applications` overrides the system one. Installing here means **a Resolve upgrade cannot undo the fix** — and it needs no root.

### Uninstall

```bash
./install.sh --uninstall
```

### Manual, if you'd rather not run a script

```bash
gcc -shared -fPIC -O2 -o ~/resolve-alsa-shim.so src/resolve-alsa-shim.c -ldl
LD_PRELOAD=~/resolve-alsa-shim.so /opt/resolve/bin/resolve
```

That second line is the entire fix — everything else in `install.sh` is just making it permanent and launchable from the dock.

---

## Verifying it works

The input meter moving is sufficient proof; you don't need to record a take. For hard evidence:

```bash
RESOLVE_ALSA_SHIM_LOG=1 resolve
```

then, in another terminal:

```bash
grep 'forcing POLLIN' /tmp/resolve-alsa-shim.log   # the fix engaging
grep -c READI          /tmp/resolve-alsa-shim.log   # reads actually happening
```

If `forcing POLLIN` never appears, your Resolve doesn't have this bug and the shim is idling — look elsewhere.

For the full flight recorder, including Fairlight's own internal narration:

```bash
make debug && RESOLVE_ALSA_SHIM_LOG=1 resolve
```

---

## Repo layout

```
src/resolve-alsa-shim.c   the fix (~60 lines of logic, heavily commented)
install.sh                build + install + uninstall, no root
diagnose.sh               "do I have this exact bug?" in 30 seconds
Makefile                  make / make debug / make install / make uninstall
docs/INVESTIGATION.md     how it was found: every dead end, with the measurement that killed it
```

---

## Reporting it upstream

If you hit this, please report it — the more confirmations, the likelier it gets fixed properly:

- **Blackmagic Design** — [DaVinci Resolve forum](https://forum.blackmagicdesign.com/), Linux section. The actionable ask: *Fairlight's ALSA capture loop should read when `snd_pcm_avail()` reports a full period regardless of `revents`, and should call `snd_pcm_start()` on capture streams.*
- **PipeWire** — [gitlab.freedesktop.org/pipewire/pipewire](https://gitlab.freedesktop.org/pipewire/pipewire/-/issues). The ask: *`snd_pcm_poll_descriptors_revents()` should report `POLLIN` for a capture stream with a full buffer.*

---

## License

MIT — see [LICENSE](LICENSE).
