/*
 * resolve-alsa-shim — makes Fairlight capture work on PipeWire
 *
 * THE BUG
 * -------
 * DaVinci Resolve's Fairlight record loop (ALSAPlayandCaptureLoop, inside
 * /opt/resolve/libs/libFairlightPage.so) gates its one and only read call on a
 * poll revents check:
 *
 *     snd_pcm_avail(capture)
 *     poll(fds)
 *     snd_pcm_poll_descriptors_revents(capture, &revents)
 *     if (revents & POLLIN)
 *         snd_pcm_readi(capture, buf, frames)   <- the ONLY capture read in the product
 *
 * PipeWire's ALSA plugin never raises POLLIN through
 * snd_pcm_poll_descriptors_revents() on a capture handle. Measured: 11070
 * consecutive calls returning revents=0x0 while snd_pcm_avail() on the same
 * handle simultaneously reported a completely full 4096-frame buffer of real
 * microphone audio. snd_pcm_readi call count: zero. Every take is digital
 * silence. Playback is unaffected because the write path is driven by
 * available space, not by revents.
 *
 * Second, smaller bug: Fairlight never calls snd_pcm_start(). The symbol is
 * not imported anywhere in the product, so the capture stream is opened and
 * prepared but never started.
 *
 * THE FIX
 * -------
 *  1. snd_pcm_poll_descriptors_revents(): if this is a capture handle, POLLIN
 *     is clear, and snd_pcm_avail_update() reports at least one full period
 *     genuinely ready, set POLLIN. Readiness is never invented.
 *  2. Any capture PCM found in PREPARED gets snd_pcm_start(); any found in
 *     XRUN gets prepare + start.
 *
 * Everything else is pass-through. Loaded via LD_PRELOAD into Resolve only.
 *
 * Build:
 *     gcc -shared -fPIC -O2 -o resolve-alsa-shim.so resolve-alsa-shim.c -ldl
 * Diagnostics build (adds a flight recorder + tees Fairlight's internal
 * debug() logger; see docs/INVESTIGATION.md):
 *     gcc -shared -fPIC -O2 -Wno-format -DSHIM_DEBUG_TEE -o ... -ldl
 *
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>

/* libasound's real headers are not needed: every type we touch is opaque and
   passed straight through. Keeping them out means the shim builds without
   libasound2-dev installed. */
typedef void snd_pcm_t;
typedef void hwp_t;
typedef void swp_t;
typedef long  sf;   /* snd_pcm_sframes_t */
typedef unsigned long uf;   /* snd_pcm_uframes_t */

#define SND_PCM_STREAM_CAPTURE  1
#define SND_PCM_STATE_PREPARED  2
#define SND_PCM_STATE_XRUN      4
#define SHIM_POLLIN             1

static int (*r_state)(snd_pcm_t*), (*r_stream)(snd_pcm_t*), (*r_start)(snd_pcm_t*),
           (*r_prepare)(snd_pcm_t*), (*r_wait)(snd_pcm_t*,int),
           (*r_open)(snd_pcm_t**,const char*,int,int), (*r_close)(snd_pcm_t*),
           (*r_hw)(snd_pcm_t*,hwp_t*), (*r_sw)(snd_pcm_t*,swp_t*),
           (*r_set_am)(snd_pcm_t*,swp_t*,uf), (*r_set_st)(snd_pcm_t*,swp_t*,uf),
           (*r_pdr)(snd_pcm_t*,void*,unsigned,unsigned short*);
static sf  (*r_avail_update)(snd_pcm_t*), (*r_avail)(snd_pcm_t*),
           (*r_readi)(snd_pcm_t*,void*,uf), (*r_writei)(snd_pcm_t*,const void*,uf);
static int (*r_hwg_ch)(const hwp_t*,unsigned*), (*r_hwg_rate)(const hwp_t*,unsigned*,int*);
static int (*r_hwg_bs)(const hwp_t*,uf*), (*r_hwg_ps)(const hwp_t*,uf*,int*);

static FILE *lg;
static double t0;
static double now(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
                         return ts.tv_sec + ts.tv_nsec/1e9; }

#define LOG(...) do{ if(lg){ fprintf(lg,"%8.2f ",now()-t0); fprintf(lg,__VA_ARGS__); \
                             fputc('\n',lg); fflush(lg);} }while(0)

static void ini(void){
    if(r_start) return;
    r_state        = dlsym(RTLD_NEXT,"snd_pcm_state");
    r_stream       = dlsym(RTLD_NEXT,"snd_pcm_stream");
    r_start        = dlsym(RTLD_NEXT,"snd_pcm_start");
    r_prepare      = dlsym(RTLD_NEXT,"snd_pcm_prepare");
    r_wait         = dlsym(RTLD_NEXT,"snd_pcm_wait");
    r_open         = dlsym(RTLD_NEXT,"snd_pcm_open");
    r_close        = dlsym(RTLD_NEXT,"snd_pcm_close");
    r_hw           = dlsym(RTLD_NEXT,"snd_pcm_hw_params");
    r_sw           = dlsym(RTLD_NEXT,"snd_pcm_sw_params");
    r_set_am       = dlsym(RTLD_NEXT,"snd_pcm_sw_params_set_avail_min");
    r_set_st       = dlsym(RTLD_NEXT,"snd_pcm_sw_params_set_start_threshold");
    r_pdr          = dlsym(RTLD_NEXT,"snd_pcm_poll_descriptors_revents");
    r_avail_update = dlsym(RTLD_NEXT,"snd_pcm_avail_update");
    r_avail        = dlsym(RTLD_NEXT,"snd_pcm_avail");
    r_readi        = dlsym(RTLD_NEXT,"snd_pcm_readi");
    r_writei       = dlsym(RTLD_NEXT,"snd_pcm_writei");
    r_hwg_ch       = dlsym(RTLD_NEXT,"snd_pcm_hw_params_get_channels");
    r_hwg_rate     = dlsym(RTLD_NEXT,"snd_pcm_hw_params_get_rate");
    r_hwg_bs       = dlsym(RTLD_NEXT,"snd_pcm_hw_params_get_buffer_size");
    r_hwg_ps       = dlsym(RTLD_NEXT,"snd_pcm_hw_params_get_period_size");
    if(getenv("RESOLVE_ALSA_SHIM_LOG")) lg = fopen("/tmp/resolve-alsa-shim.log","a");
    t0 = now();
    LOG("=== resolve-alsa-shim attached ===");
}

/* Learned from the last successful snd_pcm_hw_params(). Resolve negotiates
   455 frames against PipeWire; the 1024 default only ever applies before the
   first hw_params call, which is before any capture can happen anyway. */
static uf cur_period = 1024;

/* FIX 2: Fairlight does not import snd_pcm_start, so a capture stream it opens
   sits in PREPARED forever, producing nothing. Start it, and recover it from
   XRUN if it ever stalls. */
static void kick(snd_pcm_t *p, const char *who){
    if(!p || r_stream(p) != SND_PCM_STREAM_CAPTURE) return;
    int st = r_state(p);
    if(st == SND_PCM_STATE_PREPARED){
        int e = r_start(p);
        LOG("[fix] %s: start cap=%p rc=%d state=%d", who, p, e, r_state(p));
    } else if(st == SND_PCM_STATE_XRUN){
        r_prepare(p);
        int e = r_start(p);
        LOG("[fix] %s: XRUN-recover cap=%p rc=%d", who, p, e);
    }
}

/* FIX 1 — the one that matters. See the header comment. */
int snd_pcm_poll_descriptors_revents(snd_pcm_t *p, void *fds, unsigned n, unsigned short *rev){
    ini();
    int e = r_pdr(p, fds, n, rev);
    if(e == 0 && rev && r_stream(p) == SND_PCM_STREAM_CAPTURE && !(*rev & SHIM_POLLIN)){
        sf a = r_avail_update(p);
        if(a >= (sf)cur_period){
            *rev |= SHIM_POLLIN;
            static unsigned f;
            if(f < 5 || f % 2000 == 0)
                LOG("[fix] revents: forcing POLLIN cap=%p n=%u avail=%ld period=%lu",
                    p, f, (long)a, cur_period);
            f++;
        }
    }
    return e;
}

/* Learn the period size, and give the flight recorder something to anchor on. */
int snd_pcm_hw_params(snd_pcm_t *p, hwp_t *h){
    ini();
    int e = r_hw(p,h);
    unsigned ch=0, rt=0; uf bs=0, ps=0;
    if(r_hwg_ch)   r_hwg_ch(h,&ch);
    if(r_hwg_rate) r_hwg_rate(h,&rt,0);
    if(r_hwg_bs)   r_hwg_bs(h,&bs);
    if(r_hwg_ps)   r_hwg_ps(h,&ps,0);
    if(ps) cur_period = ps;
    LOG("hw pcm=%p %s ch=%u rate=%u buf=%lu period=%lu rc=%d",
        p, r_stream(p)?"CAP":"PLAY", ch, rt, bs, ps, e);
    return e;
}

/* Every entry point Fairlight might reach a capture handle through gets the
   kick, so the stream is running no matter which one it touches first. */
sf snd_pcm_avail_update(snd_pcm_t *p){ ini(); kick(p,"avail_update"); return r_avail_update(p); }
sf snd_pcm_avail(snd_pcm_t *p){        ini(); kick(p,"avail");        return r_avail(p); }
int snd_pcm_wait(snd_pcm_t *p,int t){  ini(); kick(p,"wait");         return r_wait(p,t); }

sf snd_pcm_readi(snd_pcm_t *p, void *b, uf n){
    ini(); kick(p,"readi");
    sf r = r_readi(p,b,n);
    static unsigned c;
    if(lg && (c < 5 || c % 500 == 0)) LOG("READI pcm=%p n=%u ask=%lu got=%ld", p, c, n, (long)r);
    c++;
    return r;
}

/* Belt and braces: Resolve 21.x never calls sw_params at all, but if a future
   build starts doing so, an avail_min or start_threshold larger than one
   period would re-close the very gate we just opened. Clamp it. */
int snd_pcm_sw_params_set_avail_min(snd_pcm_t *p, swp_t *s, uf v){
    ini();
    uf use = v;
    if(r_stream(p) == SND_PCM_STREAM_CAPTURE && v > cur_period){
        use = cur_period;
        LOG("[fix] clamp avail_min %lu -> %lu cap=%p", v, use, p);
    }
    return r_set_am(p,s,use);
}
int snd_pcm_sw_params_set_start_threshold(snd_pcm_t *p, swp_t *s, uf v){
    ini();
    uf use = v;
    if(r_stream(p) == SND_PCM_STREAM_CAPTURE && v > cur_period){
        use = cur_period;
        LOG("[fix] clamp start_threshold %lu -> %lu cap=%p", v, use, p);
    }
    return r_set_st(p,s,use);
}

int snd_pcm_open(snd_pcm_t **pp, const char *n, int s, int m){
    ini();
    int e = r_open(pp,n,s,m);
    LOG("open %s %s mode=%d rc=%d pcm=%p", n?n:"?", s?"CAP":"PLAY", m, e, e==0?*pp:0);
    return e;
}
int snd_pcm_close(snd_pcm_t *p){
    ini();
    LOG("close pcm=%p %s", p, r_stream(p)?"CAP":"PLAY");
    return r_close(p);
}

#ifdef SHIM_DEBUG_TEE
/* Diagnostics only, and off in the default build.
 *
 * libFairlightPage.so exports its own internal logger, _Z5debugPKcz
 * (C++: debug(char const*, ...)), and calls it through the PLT — so it is
 * interposable. Tee-ing it is what made the bug visible: Fairlight prints
 *     revents = 0:0  initalAvailablePlay 4096  availplay 133  availcap 4096
 * on every loop iteration, which is the whole diagnosis in one line.
 *
 * Note this REPLACES Fairlight's logger rather than forwarding to it, so its
 * own log output goes here instead of wherever it normally lands. That is why
 * it is not in the default build.
 *
 * Do NOT try to forward to the real function via dlsym(RTLD_NEXT, ...):
 * libFairlightPage.so is dlopen'd without RTLD_GLOBAL, so RTLD_NEXT cannot
 * see it, dlsym returns NULL, and calling it kills Resolve instantly.
 */
#include <stdarg.h>
int _Z5debugPKcz(const char *fmt, ...){
    ini();
    char b[2048];
    va_list ap; va_start(ap,fmt);
    vsnprintf(b,sizeof b,fmt,ap);
    va_end(ap);
    int L = 0; while(b[L]) L++;
    while(L > 0 && (b[L-1]=='\n' || b[L-1]=='\r')) b[--L] = 0;
    if(lg && L){ fprintf(lg,"%8.2f [FL] %s\n", now()-t0, b); fflush(lg); }
    return 0;
}

/* Playback-side sampler, so the log shows the output engine running alongside
   whatever the capture side is (or isn't) doing. */
sf snd_pcm_writei(snd_pcm_t *p, const void *b, uf n){
    ini();
    sf r = r_writei(p,b,n);
    static unsigned c;
    if(lg && (c < 3 || c % 1000 == 0))
        LOG("writei pcm=%p n=%u ask=%lu got=%ld state=%d", p, c, n, (long)r, r_state(p));
    c++;
    return r;
}
#endif /* SHIM_DEBUG_TEE */
