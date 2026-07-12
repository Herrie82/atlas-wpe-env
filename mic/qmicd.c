/*
 * qmicd — TouchPad microphone bridge for Atlas.  (DIRECT-ALSA rewrite, 2026-07-12)
 *
 * WHAT CHANGED / WHY
 * ------------------
 * The original qmicd drove a webOS media-server `captureV3` recording, on the belief
 * (inherited from decompiling audiod) that the DMIC is only clocked while a media-server
 * recording is active and that `arecord hw:0` yields silence.  THAT WAS WRONG.  Measured
 * on-device: `arecord -D hw:0 -f S16_LE -c1 -r16000 -t raw` captures REAL, full-scale mic
 * audio (peak 32768, rms ~410) with NO media-server involved and hw:0 free.  The old path
 * was silent because the media-server `captureV3` uses the QDSP encoder (`/dev/msm_pcm_in`),
 * which needs an audiod session->device route (`Record`/`speaker_mono_tx` binding) that never
 * happened for our session -> flat silence.  (The old "MIC CAPTURING AUDIO" verdict was a
 * false positive from a nonzero-byte count fooled by a ~2 LSB DC offset; real RMS was 1.7.)
 *
 * So qmicd now just captures ALSA hw:0 directly via `arecord` and republishes fixed 20 ms
 * S16LE chunks to the SAME shm ring + unix socket the Atlas gst side (libgstqmicsrc.so)
 * already speaks.  No LunaService, no media-server, no FIFO.  qmicd is still the single owner
 * of the (exclusive) hw:0 capture, started from wrapper-BrowserServer under the SYSTEM env.
 *
 * PROTOCOL (unchanged, so gstqmicsrc needs no change)
 *   shm  QMICD_SHM : struct qmicd_hdr, then NUM_SLOTS chunk slots one page in.
 *   sock QMICD_SOCK: server->client 8-byte {uint32 seq; uint32 slot} per ready chunk.
 *   One client at a time (WebKit has one mic capturer).  Client connect -> start arecord;
 *   client disconnect / arecord EOF -> stop arecord and release hw:0.
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
#include <sys/wait.h>
#include <sys/file.h>

#define QMICD_SHM    "/tmp/qmicd.shm"
#define QMICD_SOCK   "/tmp/qmicd.sock"
#define QMICD_LOCK   "/tmp/qmicd.lock"
#define QMICD_MAGIC  0x44494d51u            /* 'QMID' */

#define RATE        16000
#define CHANNELS    1
#define BYTES_SMP   2                       /* S16LE */
#define CHUNK_MS    20
#define CHUNK_BYTES ((RATE*CHANNELS*BYTES_SMP*CHUNK_MS)/1000)   /* 20ms = 640 B @16k mono */
#define NUM_SLOTS   8
#define SLOT0_OFF   4096u

struct qmicd_hdr {
    uint32_t magic, rate, channels, fmt /*1=S16LE*/, chunk_bytes, num_slots, seq, pad;
};
struct chunk_msg { uint32_t seq, slot; };

static uint8_t *g_shm; static struct qmicd_hdr *g_hdr;
static volatile sig_atomic_t g_run = 1;
static void on_sig(int s){ (void)s; g_run = 0; }

/* Apply the WM8994 record route (DMIC -> capture) the same way qspkd forces the speaker
 * route: audiod would set this via UCM, but our capture doesn't go through audiod's policy.
 * These are the mic-relevant csets from the msm_media_case "Speaker" record EnableSequence;
 * they match the known-good on-device state under which arecord captures real audio. */
static void enable_mic(void) {
    system(
      "amixer -c 0 cset name='ADC OSR' 0 >/dev/null 2>&1; "
      "amixer -c 0 cset name='AIF2ADCL DRC Switch' on >/dev/null 2>&1; "
      "amixer -c 0 cset name='AIF2ADC Volume' 114,114 >/dev/null 2>&1; "
      "amixer -c 0 cset name='AIF2ADCL Source' 0 >/dev/null 2>&1; "
      "amixer -c 0 cset name='AIF2ADCR Source' 1 >/dev/null 2>&1; "
      "amixer -c 0 cset name='AIF2ADC HPF Switch' on,on >/dev/null 2>&1; "
      "amixer -c 0 cset name='AIF2ADC HPF Mode' 2 >/dev/null 2>&1; "
      "amixer -c 0 cset name='ADCL Mux' 1 >/dev/null 2>&1");
}

/* fork+exec arecord writing raw S16LE PCM to a pipe; returns child pid, *rfd = read end. */
static pid_t start_arecord(int *rfd) {
    int p[2];
    if (pipe(p) < 0) { perror("qmicd: pipe"); return -1; }
    pid_t pid = fork();
    if (pid < 0) { perror("qmicd: fork"); close(p[0]); close(p[1]); return -1; }
    if (pid == 0) {
        dup2(p[1], STDOUT_FILENO);
        close(p[0]); close(p[1]);
        execl("/usr/bin/arecord", "arecord", "-D", "hw:0",
              "-f", "S16_LE", "-c", "1", "-r", "16000", "-t", "raw", "-", (char*)0);
        _exit(127);
    }
    close(p[1]);
    *rfd = p[0];
    return pid;
}

/* read exactly n bytes; 0 = EOF, -1 = error */
static int read_all(int fd, void *buf, size_t n) {
    char *b = buf;
    while (n > 0) {
        ssize_t r = read(fd, b, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return 0;
        b += r; n -= (size_t)r;
    }
    return 1;
}

/* Serve one client: capture hw:0 via arecord, publish chunks until the client goes away
 * or arecord dies.  Returns when hw:0 should be released. */
static void serve(int cfd) {
    enable_mic();
    int rfd = -1;
    pid_t ar = start_arecord(&rfd);
    if (ar < 0) return;
    fprintf(stderr, "qmicd: capturing hw:0 (arecord pid %d) -> client\n", (int)ar);

    /* Notice a dead client without blocking capture: check writability via the send() error. */
    uint32_t seq = 0;
    uint8_t chunk[CHUNK_BYTES];
    for (;;) {
        int rc = read_all(rfd, chunk, sizeof chunk);
        if (rc <= 0) { fprintf(stderr, "qmicd: arecord EOF/err\n"); break; }
        uint32_t slot = seq % NUM_SLOTS;
        memcpy(g_shm + SLOT0_OFF + (size_t)slot * CHUNK_BYTES, chunk, CHUNK_BYTES);
        g_hdr->seq = seq;
        struct chunk_msg msg = { seq, slot };
        ssize_t w = write(cfd, &msg, sizeof msg);
        if (w != (ssize_t)sizeof msg) { fprintf(stderr, "qmicd: client gone\n"); break; }
        seq++;
    }
    /* stop arecord + release hw:0 */
    kill(ar, SIGTERM);
    close(rfd);
    int st; waitpid(ar, &st, 0);
    fprintf(stderr, "qmicd: capture stopped, hw:0 released\n");
}

int main(void) {
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig); signal(SIGPIPE, SIG_IGN);
    setbuf(stderr, NULL);

    /* single-instance guard (replaces the old LSRegister guard): a 2nd qmicd must NOT
     * unlink+rebind the running instance's socket. flock is held for the process lifetime. */
    int lk = open(QMICD_LOCK, O_CREAT|O_RDWR, 0644);
    if (lk < 0 || flock(lk, LOCK_EX|LOCK_NB) < 0) {
        fprintf(stderr, "qmicd: another instance is running (lock held); exiting\n");
        return 0;
    }

    size_t shm_sz = SLOT0_OFF + (size_t)NUM_SLOTS * CHUNK_BYTES;
    int shm_fd = open(QMICD_SHM, O_RDWR|O_CREAT|O_TRUNC, 0666);
    if (shm_fd < 0) { perror("qmicd: open shm"); return 3; }
    if (ftruncate(shm_fd, shm_sz) < 0) { perror("qmicd: ftruncate"); return 3; }
    g_shm = mmap(0, shm_sz, PROT_READ|PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (g_shm == MAP_FAILED) { perror("qmicd: mmap"); return 3; }
    memset(g_shm, 0, SLOT0_OFF);
    g_hdr = (struct qmicd_hdr*)g_shm;
    *g_hdr = (struct qmicd_hdr){ QMICD_MAGIC, RATE, CHANNELS, 1, CHUNK_BYTES, NUM_SLOTS, 0, 0 };

    unlink(QMICD_SOCK);
    int sfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sfd < 0) { perror("qmicd: socket"); return 4; }
    struct sockaddr_un addr; memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX; strncpy(addr.sun_path, QMICD_SOCK, sizeof addr.sun_path - 1);
    if (bind(sfd, (struct sockaddr*)&addr, sizeof addr) < 0) { perror("qmicd: bind"); return 4; }
    chmod(QMICD_SOCK, 0666);
    if (listen(sfd, 1) < 0) { perror("qmicd: listen"); return 4; }
    fprintf(stderr, "qmicd: ready (direct ALSA hw:0) shm=%s sock=%s %dHz S16LE x%d %dB chunks\n",
            QMICD_SHM, QMICD_SOCK, RATE, CHANNELS, CHUNK_BYTES);

    while (g_run) {
        int cfd = accept(sfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; perror("qmicd: accept"); break; }
        fprintf(stderr, "qmicd: client connected\n");
        serve(cfd);
        close(cfd);
    }
    unlink(QMICD_SOCK);
    return 0;
}
