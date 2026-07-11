/* qmicd_testclient — validate the qmicd chain end to end.
 * Connects to /tmp/qmicd.sock (which makes qmicd start the media-server recording),
 * reads {seq,slot} chunk messages, copies each PCM chunk out of the shm ring, appends
 * to /tmp/mic_capture.raw (S16LE 16k mono), and reports nonzero-sample count so we can
 * tell the DMIC actually captured audio (not silence). Ctrl-C / N chunks then exits.
 * Build: atlas gcc125 (socket + mmap only, no LS/glib).  Run AFTER starting qmicd. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
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
    int want = (argc > 1) ? atoi(argv[1]) : 100;     /* how many chunks to grab (~2s @100) */
    struct sockaddr_un a; int fd, sfd, out;
    uint8_t *shm; struct qmicd_hdr *h;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&a, 0, sizeof(a)); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, QMICD_SOCK, sizeof(a.sun_path)-1);
    if (connect(fd, (struct sockaddr*)&a, sizeof(a)) < 0) { perror("connect (is qmicd up?)"); return 1; }
    printf("connected -> qmicd should now be starting the media-server recording\n");

    sfd = open(QMICD_SHM, O_RDONLY);
    if (sfd < 0) { perror("open shm"); return 2; }
    size_t sz = SLOT0_OFF + (size_t)NUM_SLOTS * CHUNK_BYTES;
    shm = mmap(0, sz, PROT_READ, MAP_SHARED, sfd, 0); close(sfd);
    if (shm == MAP_FAILED) { perror("mmap"); return 2; }
    h = (struct qmicd_hdr*)shm;
    printf("shm hdr: magic=%08x rate=%u ch=%u fmt=%u chunk=%u slots=%u\n",
           h->magic, h->rate, h->channels, h->fmt, h->chunk_bytes, h->num_slots);

    out = open("/tmp/mic_capture.raw", O_WRONLY|O_CREAT|O_TRUNC, 0666);
    long total = 0, nz = 0; int got = 0;
    for (; got < want; got++) {
        struct chunk_msg m;
        ssize_t r = read(fd, &m, sizeof(m));
        if (r != (ssize_t)sizeof(m)) { printf("socket closed after %d chunks\n", got); break; }
        const uint8_t *p = shm + SLOT0_OFF + (size_t)m.slot * CHUNK_BYTES;
        uint32_t cb = h->chunk_bytes ? h->chunk_bytes : CHUNK_BYTES;
        if (cb > CHUNK_BYTES) cb = CHUNK_BYTES;
        if (out >= 0) { ssize_t w = write(out, p, cb); (void)w; }
        for (uint32_t i = 0; i < cb; i++) { total++; if (p[i]) nz++; }
    }
    if (out >= 0) close(out);
    printf("received %d chunks, %ld bytes, NONZERO=%ld (%s)\n",
           got, total, nz, nz ? "MIC CAPTURING AUDIO" : "SILENCE — QDSP not delivering");
    close(fd); munmap(shm, sz);
    return 0;
}
