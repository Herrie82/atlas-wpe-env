/* qmicd_amp — like qmicd_testclient but reports REAL amplitude (peak/rms/loud%),
 * not the misleading nonzero-byte count. A ~2 LSB DC offset made the old test say
 * "MIC CAPTURING AUDIO" on pure silence. Connect -> qmicd starts the media-server
 * recording -> pull N chunks from the shm ring -> print peak/rms so we can tell if
 * the DMIC route actually delivers sound. Build: atlas gcc125 (socket+mmap only). */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#define QMICD_SHM   "/tmp/qmicd.shm"
#define QMICD_SOCK  "/tmp/qmicd.sock"
#define SLOT0_OFF   4096u
#define CHUNK_BYTES 640
#define NUM_SLOTS   8

struct qmicd_hdr { uint32_t magic, rate, channels, fmt, chunk_bytes, num_slots, seq, pad; };
struct chunk_msg { uint32_t seq, slot; };

int main(int argc, char **argv) {
    int want = (argc > 1) ? atoi(argv[1]) : 100;
    const char *tag = (argc > 2) ? argv[2] : "";
    struct sockaddr_un a; int fd, sfd;
    uint8_t *shm; struct qmicd_hdr *h;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, QMICD_SOCK, sizeof(a.sun_path)-1);
    if (connect(fd, (struct sockaddr*)&a, sizeof(a)) < 0) { perror("connect (qmicd up?)"); return 1; }

    sfd = open(QMICD_SHM, O_RDONLY);
    if (sfd < 0) { perror("open shm"); return 2; }
    size_t sz = SLOT0_OFF + (size_t)NUM_SLOTS * CHUNK_BYTES;
    shm = mmap(0, sz, PROT_READ, MAP_SHARED, sfd, 0); close(sfd);
    if (shm == MAP_FAILED) { perror("mmap"); return 2; }
    h = (struct qmicd_hdr*)shm;

    int win = (argc > 3) ? atoi(argv[3]) : 0;   /* 0 = single summary; >0 = per-window */
    double sumsq = 0; long ns = 0, loud = 0; int peak = 0; int got = 0;
    int wc = 0; double wsq = 0; long wns = 0; int wpeak = 0; int widx = 0;
    for (; got < want; got++) {
        struct chunk_msg m;
        if (read(fd, &m, sizeof(m)) != (ssize_t)sizeof(m)) { printf("socket closed after %d chunks\n", got); break; }
        const int16_t *p = (const int16_t*)(shm + SLOT0_OFF + (size_t)m.slot * CHUNK_BYTES);
        uint32_t cb = h->chunk_bytes ? h->chunk_bytes : CHUNK_BYTES;
        if (cb > CHUNK_BYTES) cb = CHUNK_BYTES;
        for (uint32_t i = 0; i < cb/2; i++) {
            int v = p[i]; int av = v < 0 ? -v : v;
            if (av > peak) peak = av;
            if (av > wpeak) wpeak = av;
            if (av > 1000) loud++;
            sumsq += (double)v * v; ns++;
            wsq += (double)v * v; wns++;
        }
        if (win && ++wc >= win) {
            double wr = wns ? sqrt(wsq/wns) : 0;
            printf("WIN[%s] w=%d chunks=%d peak=%d rms=%.1f %s\n", tag, widx, wc, wpeak, wr,
                   (wpeak>2000 && wr>40) ? "<== SOUND" : "");
            fflush(stdout);
            widx++; wc = 0; wsq = 0; wns = 0; wpeak = 0;
        }
    }
    double rms = ns ? sqrt(sumsq/ns) : 0;
    double loudpct = ns ? 100.0*loud/ns : 0;
    printf("AMP[%s] chunks=%d samples=%ld peak=%d rms=%.1f loud=%.2f%% -> %s\n",
           tag, got, ns, peak, rms, loudpct,
           (peak > 2000 && rms > 40) ? "REAL SOUND" : "SILENCE");
    close(fd); munmap(shm, sz);
    return 0;
}
