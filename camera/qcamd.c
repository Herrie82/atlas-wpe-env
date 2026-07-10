/*
 * qcamd — TouchPad camera daemon (Camera Path B).
 * Runs the closed libqcameralib HAL (which only works under the system glibc-2.8/glib) and
 * publishes NV12 preview frames to a shared-memory ring + a unix socket, so the WebKit/Atlas
 * side (atlas glibc-2.25 + staging glib) can consume frames WITHOUT dlopening the HAL itself
 * (which hangs in that runtime).
 *
 * Model: camera runs only while a client is connected (so getUserMedia turns it on/off).
 *   accept() -> HAL previewInit/allocateBuffers/previewStart -> loop{ takePreviewFrame ->
 *   getPreviewBuffer -> memcpy into shm slot -> send {seq,slot} over socket -> returnPreviewFrame }
 *   -> on client disconnect: previewStop/previewDeInit -> back to accept().
 *
 * Build: PalmPDK arm-none-linux-gnueabi-gcc-4.3.3 (device glibc 2.8). gcc 4.3 = C89 decls-at-top.
 *
 * SHM layout (file QCAMD_SHM): [ struct qcamd_hdr @0 ][ slot0 @QCAMD_SLOT0 ][ slot1 ]...
 * Socket QCAMD_SOCK: server->client 8-byte {uint32 seq; uint32 slot} per ready frame.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

#define QCAMD_SHM   "/tmp/qcamd.shm"
#define QCAMD_SOCK  "/tmp/qcamd.sock"
#define QCAMD_MAGIC 0x4d414351u        /* 'QCAM' */
#define NUM_SLOTS   4
#define SLOT0_OFF   4096u              /* slots start one page in */
#define MAX_FRAME   (1280*1024*2)      /* cap shm slot size */

struct qcamd_hdr {
    uint32_t magic, width, height, fourcc, frame_size, num_slots, seq, pad;
};
struct frame_msg { uint32_t seq, slot; };

typedef void (*fn_set_config)(uint32_t *cfg);
typedef int  (*fn_void)(void);
typedef int  (*fn_take)(uint32_t *out, int *timeout);
typedef int  (*fn_getbuf)(int idx, uint32_t *out);
typedef int  (*fn_ret)(uint32_t *frame);

static volatile int g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

int main(int argc, char **argv) {
    void *hal;
    fn_set_config set_config; fn_void preview_init, alloc_bufs, preview_start, preview_stop, preview_deinit;
    fn_take take_frame; fn_getbuf get_buf; fn_ret ret_frame;
    int shm_fd, srv_fd, cli_fd;
    uint8_t *shm; size_t shm_sz;
    struct qcamd_hdr *hdr;
    struct sockaddr_un addr;
    uint32_t cfg[8];
    uint32_t frame_size = 0, width = 0, height = 0;
    (void)argc; (void)argv;

    signal(SIGINT, on_sig); signal(SIGTERM, on_sig); signal(SIGPIPE, SIG_IGN);
    setbuf(stdout, NULL);

    /* --- load HAL --- */
    hal = dlopen("/usr/lib/libqcameralib.so", RTLD_NOW | RTLD_GLOBAL);
    if (!hal) { printf("qcamd: dlopen failed: %s\n", dlerror()); return 1; }
    set_config    = (fn_set_config)dlsym(hal, "qcamera_set_config");
    preview_init  = (fn_void)dlsym(hal, "qcamera_previewInit");
    alloc_bufs    = (fn_void)dlsym(hal, "qcamera_allocateBuffers");
    preview_start = (fn_void)dlsym(hal, "qcamera_previewStart");
    preview_stop  = (fn_void)dlsym(hal, "qcamera_previewStop");
    preview_deinit= (fn_void)dlsym(hal, "qcamera_previewDeInit");
    take_frame    = (fn_take)dlsym(hal, "qcamera_takePreviewFrame");
    get_buf       = (fn_getbuf)dlsym(hal, "qcamera_getPreviewBuffer");
    ret_frame     = (fn_ret)dlsym(hal, "qcamera_returnPreviewFrame");
    if (!set_config||!preview_init||!preview_start||!take_frame||!get_buf) {
        printf("qcamd: missing HAL symbols\n"); return 2;
    }

    /* --- shm --- */
    shm_sz = SLOT0_OFF + (size_t)NUM_SLOTS * MAX_FRAME;
    shm_fd = open(QCAMD_SHM, O_RDWR|O_CREAT|O_TRUNC, 0666);
    if (shm_fd < 0) { perror("qcamd: open shm"); return 3; }
    if (ftruncate(shm_fd, shm_sz) < 0) { perror("qcamd: ftruncate"); return 3; }
    shm = (uint8_t*)mmap(0, shm_sz, PROT_READ|PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (shm == MAP_FAILED) { perror("qcamd: mmap"); return 3; }
    memset(shm, 0, SLOT0_OFF);
    hdr = (struct qcamd_hdr*)shm;
    hdr->magic = QCAMD_MAGIC; hdr->num_slots = NUM_SLOTS;

    /* --- listening socket --- */
    unlink(QCAMD_SOCK);
    srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv_fd < 0) { perror("qcamd: socket"); return 4; }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, QCAMD_SOCK, sizeof(addr.sun_path)-1);
    if (bind(srv_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("qcamd: bind"); return 4; }
    chmod(QCAMD_SOCK, 0666);
    if (listen(srv_fd, 1) < 0) { perror("qcamd: listen"); return 4; }
    printf("qcamd: ready, shm=%s sock=%s (%d slots x %d)\n", QCAMD_SHM, QCAMD_SOCK, NUM_SLOTS, MAX_FRAME);

    while (g_run) {
        uint32_t seq = 0;
        int rc, streaming = 0;

        cli_fd = accept(srv_fd, 0, 0);
        if (cli_fd < 0) { if (errno==EINTR) break; perror("qcamd: accept"); continue; }
        printf("qcamd: client connected -> starting camera\n");

        memset(cfg, 0, sizeof(cfg));
        set_config(cfg);
        rc = preview_init();      printf("qcamd: previewInit rc=%d\n", rc);
        if (rc != 0) goto client_done;
        if (alloc_bufs) { rc = alloc_bufs(); printf("qcamd: allocateBuffers rc=%d\n", rc); }
        rc = preview_start();     printf("qcamd: previewStart rc=%d\n", rc);
        if (rc != 0) goto client_done;
        streaming = 1;

        while (g_run) {
            uint32_t fr[9], bi[9], slot;
            int tmo[2]; uint32_t vaddr, sz;
            struct frame_msg msg;

            tmo[0] = 2; tmo[1] = 0;
            memset(fr, 0, sizeof(fr));
            rc = take_frame(fr, tmo);
            if (rc != 0) { printf("qcamd: takePreviewFrame rc=%d\n", rc); continue; }

            memset(bi, 0, sizeof(bi));
            get_buf(fr[7], bi);
            vaddr = bi[2] ? bi[2] : bi[0];
            sz    = bi[8] ? bi[8] : (bi[5]*bi[6]*3/2);
            if (vaddr <= 0x1000 || sz == 0 || sz > MAX_FRAME) {
                if (ret_frame) ret_frame(fr);
                continue;
            }
            if (!frame_size) {
                width = bi[5]; height = bi[6]; frame_size = sz;
                hdr->width = width; hdr->height = height;
                hdr->fourcc = 0x3231564e /* NV12 */; hdr->frame_size = frame_size;
                printf("qcamd: format %ux%u NV12 frame_size=%u\n", width, height, frame_size);
            }
            slot = seq % NUM_SLOTS;
            memcpy(shm + SLOT0_OFF + (size_t)slot * MAX_FRAME, (void*)vaddr, sz);
            hdr->seq = seq;
            if (ret_frame) ret_frame(fr);

            msg.seq = seq; msg.slot = slot;
            if (write(cli_fd, &msg, sizeof(msg)) != (int)sizeof(msg)) {
                printf("qcamd: client gone (write err)\n");
                break;
            }
            seq++;
        }

    client_done:
        if (streaming) {
            if (preview_stop)   preview_stop();
            if (preview_deinit) preview_deinit();
        }
        close(cli_fd);
        frame_size = 0;
        printf("qcamd: client disconnected -> camera stopped\n");
    }

    close(srv_fd); unlink(QCAMD_SOCK);
    munmap(shm, shm_sz); close(shm_fd); unlink(QCAMD_SHM);
    dlclose(hal);
    printf("qcamd: exit\n");
    return 0;
}
