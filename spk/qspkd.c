/* qspkd — Atlas speaker daemon. The output analog of qmicd.
 *
 * The atlas browser's WebProcess (glibc-2.52) cannot load the device's PulseAudio 0.9.22 libpulse (built for
 * the old webOS glibc) — it SIGSEGVs. So the in-browser gst sink "atlasqspksink" (libgstatlasqspksink.so) has
 * NO pulse dependency: it just streams raw PCM to /tmp/qspkd.sock. THIS daemon runs under the SYSTEM glibc
 * (started by the BS wrapper before the atlas LD_LIBRARY_PATH, exactly like qcamd), reads that PCM, and plays
 * it via the system pa_simple -> PulseAudio -> audiod -> speaker.
 *
 * Protocol (atlas sink -> qspkd, one connection = one playback stream):
 *   struct { u32 magic=0x5153504b 'QSPK'; u32 format; u32 rate; u32 channels; }  then raw interleaved PCM.
 * format: 0=S16LE 1=S16BE 2=F32LE 3=S32LE 4=U8. One client at a time (the browser has one audio sink).
 * Blocking pa_simple_write provides backpressure so the sink's socket send() paces to real time. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <dlfcn.h>
#include <pulse/simple.h>   /* pa_simple type + pa_sample_spec/pa_sample_format_t/PA_* enums only */

/* We DLOPEN libpulse-simple at runtime instead of linking it — the device libpulse (0.9.22) drags a big
 * transitive chain (libpulsecommon/sndfile/gdbm/samplerate) whose libc.so linker-script uses absolute /lib
 * paths that break a host cross-link. dlopen sidesteps all of it: qspkd links only libc + libdl. */
static pa_simple *(*p_new)(const char*, const char*, pa_stream_direction_t, const char*, const char*,
                           const pa_sample_spec*, const pa_channel_map*, const pa_buffer_attr*, int*);
static int  (*p_write)(pa_simple*, const void*, size_t, int*);
static int  (*p_drain)(pa_simple*, int*);
static void (*p_free)(pa_simple*);

static int load_pulse(void) {
    void *h = dlopen("libpulse-simple.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "qspkd: dlopen libpulse-simple failed: %s\n", dlerror()); return -1; }
    p_new   = dlsym(h, "pa_simple_new");
    p_write = dlsym(h, "pa_simple_write");
    p_drain = dlsym(h, "pa_simple_drain");
    p_free  = dlsym(h, "pa_simple_free");
    if (!p_new || !p_write || !p_drain || !p_free) { fprintf(stderr, "qspkd: missing pa_simple symbols\n"); return -1; }
    return 0;
}

#define QSPK_SOCK  "/tmp/qspkd.sock"
#define QSPK_MAGIC 0x5153504bU

struct qspk_hdr { uint32_t magic, format, rate, channels; };

static pa_sample_format_t map_fmt(uint32_t f) {
    switch (f) {
        case 0: return PA_SAMPLE_S16LE;
        case 1: return PA_SAMPLE_S16BE;
        case 2: return PA_SAMPLE_FLOAT32LE;
        case 3: return PA_SAMPLE_S32LE;
        case 4: return PA_SAMPLE_U8;
        default: return PA_SAMPLE_INVALID;
    }
}

/* read exactly n bytes; 0 = clean EOF, -1 = error */
static int read_all(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return 0;
        p += r; n -= (size_t)r;
    }
    return 1;
}

/* Route the WM8994 DAC1 to the SPEAKER output. webOS audiod does this when IT plays, but our (non-audiod)
 * PulseAudio stream doesn't trigger that policy, so DAC1 lands on the silent headphone path and playback is
 * inaudible even though pcm0p is RUNNING. Force the speaker route on (control NAMES — numids shift across
 * boots). root, so amixer can set it. Verified on-device: switches held under audiod during playback. */
static void enable_speaker(void) {
    system("for c in 'SPKL DAC1 Switch' 'SPKR DAC1 Switch' 'SPKL Output Switch' 'SPKR Output Switch'; do "
           "amixer -c 0 cset name=\"$c\" on >/dev/null 2>&1; done; "
           "amixer -c 0 cset name='SPKL DAC1 Volume' 1 >/dev/null 2>&1; "
           "amixer -c 0 cset name='SPKR DAC1 Volume' 1 >/dev/null 2>&1; "
           "amixer -c 0 cset name='SPKL Output Volume' 63 >/dev/null 2>&1; "
           "amixer -c 0 cset name='SPKR Output Volume' 63 >/dev/null 2>&1");
}

/* Serve one connected client until it disconnects. */
static void serve(int cfd) {
    struct qspk_hdr h;
    int rc = read_all(cfd, &h, sizeof h);
    if (rc <= 0) { fprintf(stderr, "qspkd: no/short header\n"); return; }
    if (h.magic != QSPK_MAGIC) { fprintf(stderr, "qspkd: bad magic 0x%x\n", h.magic); return; }

    pa_sample_spec ss;
    ss.format   = map_fmt(h.format);
    ss.rate     = h.rate;
    ss.channels = (uint8_t)h.channels;
    if (ss.format == PA_SAMPLE_INVALID || ss.rate == 0 || ss.channels == 0 || ss.channels > 8) {
        fprintf(stderr, "qspkd: bad spec fmt=%u rate=%u ch=%u\n", h.format, h.rate, h.channels);
        return;
    }

    int err = 0;
    pa_simple *pa = p_new(NULL, "AtlasBrowser", PA_STREAM_PLAYBACK, NULL, "webkit",
                          &ss, NULL, NULL, &err);
    if (!pa) { fprintf(stderr, "qspkd: pa_simple_new failed (err=%d)\n", err); return; }
    enable_speaker();   /* route DAC1 -> speaker (audiod won't for our stream) */
    fprintf(stderr, "qspkd: playing %uch %uHz fmt=%u\n", h.channels, h.rate, h.format);

    static char buf[8192];
    for (;;) {
        ssize_t r = read(cfd, buf, sizeof buf);
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (r == 0) break;   /* client closed -> stream done */
        if (p_write(pa, buf, (size_t)r, &err) < 0) {
            fprintf(stderr, "qspkd: pa_simple_write failed (err=%d)\n", err);
            break;
        }
    }
    p_drain(pa, &err);
    p_free(pa);
    fprintf(stderr, "qspkd: stream ended\n");
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    if (load_pulse() != 0) return 1;
    unlink(QSPK_SOCK);

    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) { perror("qspkd: socket"); return 1; }
    struct sockaddr_un addr; memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, QSPK_SOCK, sizeof addr.sun_path - 1);
    if (bind(sfd, (struct sockaddr *)&addr, sizeof addr) < 0) { perror("qspkd: bind"); return 1; }
    chmod(QSPK_SOCK, 0666);
    if (listen(sfd, 1) < 0) { perror("qspkd: listen"); return 1; }
    fprintf(stderr, "qspkd: listening on %s\n", QSPK_SOCK);

    for (;;) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; perror("qspkd: accept"); break; }
        serve(cfd);
        close(cfd);
    }
    return 0;
}
