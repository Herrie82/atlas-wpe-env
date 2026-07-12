/*
 * qmicd — TouchPad WebRTC microphone daemon for Atlas.  (scaffold; mirrors qcamd)
 *
 * WHY THIS EXISTS
 * --------------
 * On the HP TouchPad the internal mic is a DIGITAL mic (DMIC) wired to the
 * Qualcomm QDSP via the WM8994 AIF2.  Direct ALSA capture (`arecord hw:0`) opens
 * the PCM but produces pure silence, because the DMIC/AIF2 is only clocked while
 * a webOS **media-server recording** is active — that is what makes `audiod`
 * enable the mic route (UCM `Force-route.0` + `msm_capture_route(speaker_mono_tx)`).
 * And `hw:0` capture is EXCLUSIVE, so Atlas cannot just open its own alsasrc.
 *
 * So qmicd (like qcamd for the camera) is the single owner of the capture:
 *   - it drives a media-server `captureV3` AUDIO recording over LunaService,
 *     pointed at a FIFO;  the media server runs `alsasrc hw:0 ! wavenc ! filesink`
 *     with the DMIC live and writes WAV to the FIFO;
 *   - qmicd reads the WAV PCM from the FIFO and republishes S16LE chunks to a
 *     shm ring + a unix socket, so the Atlas/WebKit gst side (glibc-2.25 staging)
 *     consumes the mic WITHOUT holding hw:0 or speaking the QDSP session itself.
 *
 * FLOW
 *   accept() Atlas client
 *     -> LS: captureV3{subscribe:true}  -> reply.location = "palm://com.palm.mediad.MediaCaptureV3_<pid>/"
 *     -> LS: <location>load            {args:[deviceUri, {deviceUri:deviceUri}]}
 *     -> LS: <location>startAudioCapture {args:[FIFO, {mimetype:"audio/vnd.wave",codecs:"1",samplerate:16000,bitrate:256000,duration:0,size:0}]}
 *   media server -> FIFO: 44-byte WAV header, then S16LE mono @16k PCM
 *   qmicd: read FIFO -> fixed chunk -> shm slot -> send {seq,slot} on socket
 *   client disconnect -> <location>stopAudioCapture{} , <location>unload{} , cancel captureV3
 *
 * PROTOCOL (identical shape to qcamd)
 *   shm  QMICD_SHM : struct qmicd_hdr, then NUM_SLOTS chunk slots one page in.
 *   sock QMICD_SOCK: server->client 8-byte {uint32 seq; uint32 slot} per ready chunk.
 *
 * BUILD: PalmPDK arm-none-linux-gnueabi-gcc-4.3.3 (device glibc-2.8), like qcamd,
 *   but ALSO links LunaService + glib:  -llunaservice -lglib-2.0  (see build.sh).
 *   Runs under the SYSTEM env (the clean upstart env, before Atlas LD_LIBRARY_PATH),
 *   same as qcamd — start it from the wrapper alongside qcamd.
 *
 * >>> TODOs marked [TODO] below are the device-specific bits to finish. <<<
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <glib.h>
#include <lunaservice.h>          /* LSRegister/LSCall/LSGmainAttach ... (PalmPDK sysroot) */

#define QMICD_SHM    "/tmp/qmicd.shm"
#define QMICD_SOCK   "/tmp/qmicd.sock"
#define QMICD_FIFO   "/tmp/qmicd.fifo"      /* media server writes WAV here */
#define QMICD_MAGIC  0x44494d51u            /* 'QMID' */
#define QMICD_SVC    "org.webosports.qmicd" /* LS2 service name (needs a role file) */

/* Capture format we request from the media server (WAV PCM). Must match the
 * `{mimetype,codecs,samplerate}` in startAudioCapture and gstqmicsrc's caps. */
#define RATE        16000
#define CHANNELS    1
#define BYTES_SMP   2                       /* S16LE */
#define CHUNK_MS    20
#define CHUNK_BYTES ((RATE*CHANNELS*BYTES_SMP*CHUNK_MS)/1000)   /* 20ms = 640 B @16k mono */
#define NUM_SLOTS   8
#define SLOT0_OFF   4096u
#define WAV_HDR     44                      /* skip streaming-WAV header from wavenc */

struct qmicd_hdr {
    uint32_t magic, rate, channels, fmt /*1=S16LE*/, chunk_bytes, num_slots, seq, pad;
};
struct chunk_msg { uint32_t seq, slot; };

/* ------------------------------------------------------------------ state */
static struct {
    LSHandle   *ls;
    GMainLoop  *loop;
    int         srv_fd, cli_fd, fifo_fd;
    guint       cli_watch, fifo_watch;
    uint8_t    *shm;   struct qmicd_hdr *hdr;
    char        location[256];      /* the captureV3 session endpoint URI */
    LSMessageToken cv3_token;       /* captureV3 subscription token (to cancel) */
    int         recording;
    uint32_t    seq;
    uint8_t     acc[CHUNK_BYTES];   /* partial-chunk accumulator */
    size_t      acc_len;
    long        skip;               /* WAV header bytes still to discard */
} S;

static volatile int g_run = 1;
static void on_sig(int s){ (void)s; g_run = 0; if (S.loop) g_main_loop_quit(S.loop); }

/* ------------------------------------------------------------ LS helpers */
/* Minimal "location" extractor — avoids a JSON dep for the scaffold. */
static int extract_str(const char *json, const char *key, char *out, size_t n){
    char pat[64]; snprintf(pat, sizeof(pat), "\"%s\":\"", key);
    const char *p = strstr(json, pat); if (!p) return 0;
    p += strlen(pat); const char *e = strchr(p, '"'); if (!e) return 0;
    size_t len = (size_t)(e - p); if (len >= n) len = n-1;
    memcpy(out, p, len); out[len] = 0; return 1;
}

static bool cb_start(LSHandle *h, LSMessage *m, void *ctx){
    (void)h; (void)ctx;
    const char *pl = LSMessageGetPayload(m);
    fprintf(stderr, "qmicd: startAudioCapture reply: %s\n", pl ? pl : "(null)");
    /* returnValue:true => the media server is now recording -> DMIC live -> FIFO fills */
    return true;
}

static bool cb_load(LSHandle *h, LSMessage *m, void *ctx){
    (void)ctx;
    const char *pl = LSMessageGetPayload(m);
    fprintf(stderr, "qmicd: load reply: %s\n", pl ? pl : "(null)");
    LSError e; LSErrorInit(&e);
    char uri[320]; snprintf(uri, sizeof(uri), "%sstartAudioCapture", S.location);
    /* WAV PCM @ RATE — matches CHUNK/gstqmicsrc caps. FIFO as the capture target. */
    char args[320];
    snprintf(args, sizeof(args),
        "{\"args\":[\"%s\",{\"mimetype\":\"audio/vnd.wave\",\"codecs\":\"1\","
        "\"bitrate\":256000,\"samplerate\":%d,\"duration\":0,\"size\":0}]}",
        QMICD_FIFO, RATE);
    if (!LSCallOneReply(S.ls, uri, args, cb_start, NULL, NULL, &e)) {
        fprintf(stderr, "qmicd: startAudioCapture LSCall failed: %s\n", e.message); LSErrorFree(&e);
    }
    (void)h; (void)m; return true;
}

static bool cb_captureV3(LSHandle *h, LSMessage *m, void *ctx){
    (void)h; (void)ctx;
    const char *pl = LSMessageGetPayload(m);
    if (!pl) return true;
    if (!S.location[0] && extract_str(pl, "location", S.location, sizeof(S.location))) {
        fprintf(stderr, "qmicd: captureV3 location=%s\n", S.location);
        LSError e; LSErrorInit(&e);
        char uri[320]; snprintf(uri, sizeof(uri), "%sload", S.location);
        /* The built-in mic input deviceUri is the well-known constant "audio:" (from the
         * mediacapture framework: captureDevicesDefault*_ list, inputtype AUDIO,
         * deviceUri:"audio:", description:"Front Microphone"). The earlier empty-"" failure
         * was the connection-binding issue (calls on a different LS handle than the
         * subscription), not the URI — qmicd issues every call on THIS one handle. */
        const char *AUDIO_DEVICE_URI = "audio:";
        char args[420];
        snprintf(args, sizeof(args),
            "{\"args\":[\"%s\",{\"deviceUri\":\"%s\"}]}", AUDIO_DEVICE_URI, AUDIO_DEVICE_URI);
        if (!LSCallOneReply(S.ls, uri, args, cb_load, NULL, NULL, &e)) {
            fprintf(stderr, "qmicd: load LSCall failed: %s\n", e.message); LSErrorFree(&e);
        }
    }
    /* Subsequent captureV3 updates carry device list / status — parse here [TODO]. */
    return true;
}

/* Open the FIFO read end (nonblock) and start the media-server recording. The
 * media server's filesink opens the FIFO write end; our read end must exist. */
static void start_capture(void){
    if (S.recording) return;
    unlink(QMICD_FIFO); mkfifo(QMICD_FIFO, 0666);
    /* O_RDWR so opening the read end doesn't block waiting for a writer, and so
     * the fifo has a persistent writer ref (no EOF churn between chunks). */
    S.fifo_fd = open(QMICD_FIFO, O_RDWR | O_NONBLOCK);
    if (S.fifo_fd < 0) { perror("qmicd: open fifo"); return; }
    S.skip = WAV_HDR; S.acc_len = 0;
    /* watch the fifo for data (added in main once fd is known) */
    S.recording = 1; S.location[0] = 0;
    LSError e; LSErrorInit(&e);
    if (!LSCall(S.ls, "palm://com.palm.mediad/service/captureV3",
                "{\"subscribe\":true}", cb_captureV3, NULL, &S.cv3_token, &e)) {
        fprintf(stderr, "qmicd: captureV3 LSCall failed: %s\n", e.message); LSErrorFree(&e);
        S.recording = 0;
    }
}

static void stop_capture(void){
    if (!S.recording) return;
    LSError e; LSErrorInit(&e);
    char uri[320];
    if (S.location[0]) {
        snprintf(uri, sizeof(uri), "%sstopAudioCapture", S.location);
        LSCallOneReply(S.ls, uri, "{\"args\":[]}", NULL, NULL, NULL, &e);
        snprintf(uri, sizeof(uri), "%sunload", S.location);
        LSCallOneReply(S.ls, uri, "{\"args\":[]}", NULL, NULL, NULL, &e);
    }
    if (S.cv3_token) { LSCallCancel(S.ls, S.cv3_token, &e); S.cv3_token = 0; }
    if (S.fifo_watch) { g_source_remove(S.fifo_watch); S.fifo_watch = 0; }
    if (S.fifo_fd >= 0) { close(S.fifo_fd); S.fifo_fd = -1; }
    S.recording = 0; S.location[0] = 0;
    fprintf(stderr, "qmicd: capture stopped\n");
}

/* ---------------------------------------------------------- fifo -> shm */
static void publish_chunk(const uint8_t *buf){
    uint32_t slot = S.seq % NUM_SLOTS;
    memcpy(S.shm + SLOT0_OFF + (size_t)slot * CHUNK_BYTES, buf, CHUNK_BYTES);
    struct chunk_msg msg = { S.seq, slot };
    S.hdr->seq = S.seq;
    if (S.cli_fd >= 0 && write(S.cli_fd, &msg, sizeof(msg)) != (int)sizeof(msg)) {
        /* client gone — main's cli watch will tear down */
    }
    S.seq++;
}

static gboolean on_fifo(GIOChannel *ch, GIOCondition cond, gpointer u){
    (void)ch; (void)u;
    if (cond & (G_IO_HUP|G_IO_ERR)) return TRUE;   /* writer not attached yet; keep watching */
    uint8_t buf[2048]; ssize_t n;
    while ((n = read(S.fifo_fd, buf, sizeof(buf))) > 0) {
        const uint8_t *p = buf; size_t left = (size_t)n;
        if (S.skip > 0) {                          /* discard WAV header */
            size_t d = (S.skip < (long)left) ? (size_t)S.skip : left;
            p += d; left -= d; S.skip -= d;
        }
        while (left) {                             /* reassemble fixed chunks */
            size_t need = CHUNK_BYTES - S.acc_len, take = (left < need) ? left : need;
            memcpy(S.acc + S.acc_len, p, take); S.acc_len += take; p += take; left -= take;
            if (S.acc_len == CHUNK_BYTES) { publish_chunk(S.acc); S.acc_len = 0; }
        }
    }
    return TRUE;
}

/* ------------------------------------------------------------ socket */
static gboolean on_client(GIOChannel *ch, GIOCondition cond, gpointer u){
    (void)ch; (void)u;
    if (cond & (G_IO_HUP|G_IO_ERR)) {              /* Atlas disconnected */
        stop_capture();
        if (S.cli_watch) { g_source_remove(S.cli_watch); S.cli_watch = 0; }
        if (S.cli_fd >= 0) { close(S.cli_fd); S.cli_fd = -1; }
        fprintf(stderr, "qmicd: client disconnected -> capture released\n");
    }
    return TRUE;
}

static gboolean on_accept(GIOChannel *ch, GIOCondition cond, gpointer u){
    (void)ch; (void)cond; (void)u;
    int fd = accept(S.srv_fd, 0, 0);
    if (fd < 0) return TRUE;
    if (S.cli_fd >= 0) { close(fd); return TRUE; }   /* single client, like qcamd */
    S.cli_fd = fd;
    GIOChannel *c = g_io_channel_unix_new(fd);
    S.cli_watch = g_io_add_watch(c, G_IO_HUP|G_IO_ERR, on_client, NULL);
    g_io_channel_unref(c);
    /* set up the fifo watch now, then kick off the media-server recording */
    start_capture();
    if (S.fifo_fd >= 0) {
        GIOChannel *f = g_io_channel_unix_new(S.fifo_fd);
        S.fifo_watch = g_io_add_watch(f, G_IO_IN|G_IO_HUP|G_IO_ERR, on_fifo, NULL);
        g_io_channel_unref(f);
    }
    fprintf(stderr, "qmicd: client connected -> starting media-server recording\n");
    return TRUE;
}

int main(int argc, char **argv){
    (void)argc; (void)argv;
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig); signal(SIGPIPE, SIG_IGN);
    setbuf(stdout, NULL); setbuf(stderr, NULL);
    memset(&S, 0, sizeof(S)); S.cli_fd = S.fifo_fd = -1;

    /* --- LunaService FIRST (before the shared socket): a duplicate qmicd must fail LSRegister
     * ("already exists") and exit HERE, before unlink()'ing + rebinding the running instance's
     * /tmp/qmicd.sock — otherwise it leaves a dead socket and qmicsrc gets "Connection refused". --- */
    S.loop = g_main_loop_new(NULL, FALSE);
    LSError e; LSErrorInit(&e);
    if (!LSRegister(QMICD_SVC, &S.ls, &e)) { fprintf(stderr, "qmicd: LSRegister: %s\n", e.message); return 5; }
    if (!LSGmainAttach(S.ls, S.loop, &e))  { fprintf(stderr, "qmicd: LSGmainAttach: %s\n", e.message); return 5; }
    fprintf(stderr, "qmicd: LS registered + attached\n");

    /* --- shm --- */
    size_t shm_sz = SLOT0_OFF + (size_t)NUM_SLOTS * CHUNK_BYTES;
    int shm_fd = open(QMICD_SHM, O_RDWR|O_CREAT|O_TRUNC, 0666);
    if (shm_fd < 0) { perror("qmicd: open shm"); return 3; }
    if (ftruncate(shm_fd, shm_sz) < 0) { perror("qmicd: ftruncate"); return 3; }
    S.shm = mmap(0, shm_sz, PROT_READ|PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (S.shm == MAP_FAILED) { perror("qmicd: mmap"); return 3; }
    memset(S.shm, 0, SLOT0_OFF);
    S.hdr = (struct qmicd_hdr*)S.shm;
    *S.hdr = (struct qmicd_hdr){ QMICD_MAGIC, RATE, CHANNELS, 1, CHUNK_BYTES, NUM_SLOTS, 0, 0 };
    fprintf(stderr, "qmicd: [1] shm mapped\n");

    /* --- unix socket --- */
    unlink(QMICD_SOCK);
    S.srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX; strncpy(addr.sun_path, QMICD_SOCK, sizeof(addr.sun_path)-1);
    if (bind(S.srv_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("qmicd: bind"); return 4; }
    chmod(QMICD_SOCK, 0666); listen(S.srv_fd, 1);

    GIOChannel *sc = g_io_channel_unix_new(S.srv_fd);
    g_io_add_watch(sc, G_IO_IN, on_accept, NULL); g_io_channel_unref(sc);

    fprintf(stderr, "qmicd: ready — shm=%s sock=%s fifo=%s (%d Hz S16LE x%d, %d B chunks)\n",
            QMICD_SHM, QMICD_SOCK, QMICD_FIFO, RATE, CHANNELS, CHUNK_BYTES);
    g_main_loop_run(S.loop);

    stop_capture();
    LSUnregister(S.ls, &e);
    unlink(QMICD_SOCK); unlink(QMICD_FIFO);
    return 0;
}
