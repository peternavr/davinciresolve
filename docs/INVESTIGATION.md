# How this bug was found

A record of the actual investigation, including the dead ends — because the dead ends are where most of the time went, and because anyone chasing a similar "it works everywhere except in this one app" problem will recognise the shape of it.

## The trap

Every early signal pointed away from the real cause:

- Audio worked perfectly on the machine, in and out, in every other application.
- Resolve's *playback* worked flawlessly — same process, same audio server, same session.
- Resolve's own logs (`ResolveDebug.txt`) reported **no audio errors whatsoever**.
- Fairlight enumerated every sound card on the system correctly, including USB interfaces.
- The UI was configured correctly — track armed, input patched, meters present.

So the natural conclusion was "a setting is wrong somewhere," and hours went into settings that were never the problem. The engine was not failing. It was succeeding at everything except the one call that mattered.

## Ruled out, each with the measurement that killed it

| Suspect | Verdict | Evidence |
|---|---|---|
| OS capture / microphone | innocent | `pw-record` from the same source: peak −8 dBFS |
| PipeWire routing into Resolve | innocent | links active, node running, correct source |
| PipeWire's ALSA plugin generally | innocent | standalone C program using Resolve's *exact* geometry (8ch, S32_LE, buf 4096) captured real audio |
| EasyEffects in the chain | innocent | direct source capture equally clean |
| Track arming / input patch / bus | innocent | verified visually; inputs 1 and 2 both tried |
| Timeline / project settings | innocent | a noise-generator take recorded fine at −18 dBFS, proving Resolve's *write* path |
| Resolve 21.0.2 vs 21.0.3 | both broken | identical behaviour on both |
| `INPUT_DEVICE` in `System Parameters.xml` | irrelevant | `0` and `−1` behave identically |
| `SYSTEM_AUDIO_ENABLED = 0` in Fairlight's log | **red herring** | disassembly showed the format string re-prints the *DeckLink* parameter; `NoSoundCard = 0` is the healthy value |
| snd-aloop kernel loopback workaround | abandoned | caused lag and crashes; fully removed |
| Missing `snd_pcm_start` | real, but insufficient alone | starting the stream still produced silence — the revents gate was the actual blocker |

## The technique that worked

Static analysis of the UI and config space was exhausted, so the next step was to watch the actual system calls.

### 1. Find the real API surface

```bash
nm -D /opt/resolve/bin/resolve          | grep snd_pcm    # → nothing
nm -D /opt/resolve/libs/libFairlightPage.so | grep snd_pcm  # → 63 symbols
```

All ALSA use lives in `libFairlightPage.so`. Critically:

- `snd_pcm_readi` is imported — and it is the **only** capture read function. No mmap capture functions at all.
- `snd_pcm_start` is **not imported anywhere in the product**.

That second fact alone is a bug: a capture stream that is never started produces nothing.

### 2. Interpose libasound and record everything

An `LD_PRELOAD` shim wrapping `snd_pcm_open/close/hw_params/sw_params/avail/avail_update/wait/readi/poll_descriptors_revents`, logging every call with handle, direction, and return value.

The decisive numbers from a 90-second run:

```
avail_update  5552 calls   ret=4096 (buffer FULL)   ~105 Hz
revents      11070 calls   rev=0x0                  every single one
READI            0 calls
sw_params        0 calls   (so no avail_min theory could hold)
writei          14 calls   (playback happily running the whole time)
```

Audio was reaching Resolve's buffer. Resolve was never taking it.

### 3. Read the machine code

`objdump -d libFairlightPage.so` (5.2 million lines) and locate the three `snd_pcm_readi` call sites:

- `ALSATestCapture` — a standalone diagnostic, not the live path
- `ALSAPlayandCaptureLoop` — ×2, the real record loop

Then walk `AlsaMainLoop`, which shows the control flow plainly:

```
ALSAInitialiseDevice(PLAYBACK, …)
ALSAInitialiseDevice(CAPTURE,  …)  → %bl
test %bl,%bl ; je 16397c8            ← capture init failure skips everything
   ALSAPlayandCaptureLoop(…)         ← the only code that calls readi
16397c8: snd_pcm_drop + snd_pcm_close
```

That produced a plausible-but-wrong hypothesis: capture initialisation must be failing. It wasn't.

### 4. Make the program narrate itself

`libFairlightPage.so` exports its own internal logger, `_Z5debugPKcz` (C++ `debug(char const*, ...)`), and calls it **through the PLT** — which makes it interposable. Hooking it turns Resolve into its own witness.

That immediately disproved the init-failure theory (`play 1 Capture 1 total = 2`, "audio interface prepared" — capture initialised *fine*) and printed the answer directly:

```
revents = 0:0   initalAvailablePlay 4096   availplay 133   availcap 4096
```

`availcap 4096` — a completely full capture buffer. `revents = 0` — the gate that decides whether to read it. Every iteration, forever.

**One caution:** do **not** try to forward to the real `debug()` via `dlsym(RTLD_NEXT, …)`. `libFairlightPage.so` is `dlopen`ed without `RTLD_GLOBAL`, so `RTLD_NEXT` cannot see it, `dlsym` returns `NULL`, and calling it kills Resolve instantly at startup. That mistake cost one crash and one relaunch cycle.

### 5. Confirm by fixing it

Set `POLLIN` when a capture handle genuinely has a period ready. Relaunch:

```
[fix] revents: forcing POLLIN cap=0x… avail=512 period=455
READI pcm=0x… ask=455 got=455
READI pcm=0x… ask=455 got=455
…
revents = 0:0   initalAvailablePlay 4096   availplay 136   availcap 135
                                                           ^^^^^^^^^^^ draining
```

`availcap` fell from a permanently pinned 4096 to 21–191. ~7,000 reads in 48 seconds, `got=455` every time. Input meters live.

## Transferable lessons

- **"Playback works, so the audio stack is fine" is not sound reasoning.** Playback and capture share almost no code. Here the write path was driven by available *space* while the read path was gated on *readiness* — one worked and one didn't, in the same process, on the same device pair.
- **An app reporting no errors is evidence of nothing.** This engine never failed. It declined to act, silently and successfully.
- **`nm -D` on a plugin library is a fast, high-value first move.** The absence of `snd_pcm_start` was visible in the first minute and was half the bug.
- **A vendor's own log strings are the cheapest instrumentation available.** Interposing one exported logger turned a black box into a narrated one.
- **Verify a symptom's source before theorising on it.** `SYSTEM_AUDIO_ENABLED = 0` looked exactly like the smoking gun for a whole round of work. Reading the code that printed it took ten minutes and showed it was echoing an unrelated DeckLink parameter.

## Reproducers

`test_capture.c` — opens `default` for capture with Resolve's parameters and never calls `snd_pcm_start`. State stays `PREPARED` (2), `avail` returns 0 forever. Add the start call and it reports 48,000 frames/sec. This is bug 2 in 40 lines.

`test_8ch.c` — clones Resolve's exact negotiated geometry (8ch, S32_LE, buf 4096) and reads with an explicit start. Result: `ch1: 40907/40960 nonzero`. This is what proved PipeWire's ALSA path itself was innocent.
