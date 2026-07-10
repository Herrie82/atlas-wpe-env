/*
 * qcam_probe — headless capture probe for the HP TouchPad closed camera HAL.
 * dlopen()s /usr/lib/libqcameralib.so and drives the qcamera_* preview API to
 * pull NV12 frames from the mt9m113 front sensor, proving the sensor->CSI->VFE->DDR
 * path works on the live 2.6.35 kernel (Camera Path A milestone 0).
 *
 * Canonical sequence (from qcam_standalonePreviewStart @ decompile 3550):
 *   set_config -> previewInit -> allocateBuffers -> previewStart -> takePreviewFrame loop
 * Overlay/fb setup inside previewInit is skipped when the config overlay-path fields
 * are null (guarded by strlen>1), so this runs headless.
 *
 * Build: PalmPDK arm-none-linux-gnueabi-gcc-4.3.3 (matches device glibc 2.8).
 * gcc 4.3 = C89-ish: declare locals at block top.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*fn_set_config)(uint32_t *cfg);
typedef int  (*fn_void)(void);
typedef int  (*fn_take)(uint32_t *out, int *timeout);   /* timeout = {tv_sec, tv_usec} */
typedef int  (*fn_getbuf)(int idx, uint32_t *out);
typedef int  (*fn_ret)(uint32_t *frame);   /* returnPreviewFrame takes the frame struct ptr, derefs +0x1c */

#define SYM(v, t, name) do { \
        v = (t)dlsym(hal, name); \
        printf("  dlsym %-28s = %p\n", name, (void*)v); \
    } while (0)

static void dump9(const char *tag, uint32_t *a) {
    int i;
    printf("  %s:", tag);
    for (i = 0; i < 9; i++) printf(" [%d]=0x%08x", i, a[i]);
    printf("\n");
}

int main(int argc, char **argv) {
    void *hal;
    fn_set_config set_config;
    fn_void preview_init, alloc_bufs, preview_start, preview_stop, preview_deinit, nbufs_fn;
    fn_take take_frame;
    fn_getbuf get_buf;
    fn_ret   ret_frame;
    uint32_t cfg[8];
    int rc, i, got = 0, nbufs;
    int capture_at = (argc > 1) ? atoi(argv[1]) : 4;   /* a few frames in, let AEC start */

    setbuf(stdout, NULL);
    printf("[qcam_probe] dlopen libqcameralib.so\n");
    hal = dlopen("/usr/lib/libqcameralib.so", RTLD_NOW | RTLD_GLOBAL);
    if (!hal) { printf("  dlopen FAILED: %s\n", dlerror()); return 1; }

    SYM(set_config,    fn_set_config, "qcamera_set_config");
    SYM(preview_init,  fn_void,       "qcamera_previewInit");
    SYM(alloc_bufs,    fn_void,       "qcamera_allocateBuffers");
    SYM(preview_start, fn_void,       "qcamera_previewStart");
    SYM(preview_stop,  fn_void,       "qcamera_previewStop");
    SYM(preview_deinit,fn_void,       "qcamera_previewDeInit");
    SYM(take_frame,    fn_take,       "qcamera_takePreviewFrame");
    SYM(get_buf,       fn_getbuf,     "qcamera_getPreviewBuffer");
    SYM(ret_frame,     fn_ret,        "qcamera_returnPreviewFrame");
    SYM(nbufs_fn,      fn_void,       "qcamera_getPreviewBuffersNum");

    if (!set_config || !preview_init || !preview_start || !take_frame || !get_buf) {
        printf("  missing required symbols, abort\n"); return 2;
    }

    memset(cfg, 0, sizeof(cfg));
    printf("[qcam_probe] set_config(zeros)\n");
    set_config(cfg);

    printf("[qcam_probe] previewInit()\n");
    rc = preview_init ? preview_init() : -1;
    printf("  previewInit rc=%d\n", rc);

    if (alloc_bufs) {
        printf("[qcam_probe] allocateBuffers()\n");
        rc = alloc_bufs();
        printf("  allocateBuffers rc=%d\n", rc);
    }

    nbufs = nbufs_fn ? nbufs_fn() : -1;
    printf("[qcam_probe] getPreviewBuffersNum = %d\n", nbufs);

    printf("[qcam_probe] previewStart()\n");
    rc = preview_start();
    printf("  previewStart rc=%d\n", rc);

    printf("[qcam_probe] frame loop (capture at frame %d)\n", capture_at);
    for (i = 0; i < capture_at + 5 && got < 2; i++) {
        uint32_t fr[9];
        int tmo[2];
        tmo[0] = 2; tmo[1] = 0;              /* 2s timeout */
        memset(fr, 0, sizeof(fr));
        rc = take_frame(fr, tmo);
        if (rc != 0) { printf("  [%02d] takePreviewFrame rc=%d (no frame)\n", i, rc); continue; }
        printf("  [%02d] frame idx=%d %ux%u size=%u\n", i, fr[7], fr[5], fr[6], fr[8]);

        if (i >= capture_at) {
            uint32_t bi[9];
            memset(bi, 0, sizeof(bi));
            get_buf(fr[7], bi);
            dump9("getPreviewBuffer", bi);
            /* candidate CPU pointers: bi[2]=*(buf+0xc)=do_mmap vaddr; bi[0] fallback */
            {
                uint32_t vaddr = bi[2] ? bi[2] : bi[0];
                uint32_t sz    = bi[8] ? bi[8] : (bi[5]*bi[6]*3/2);
                if (vaddr > 0x1000 && sz > 0 && sz < (8u<<20)) {
                    char path[64];
                    FILE *f;
                    sprintf(path, "/tmp/qcam_frame_%d.nv12", got);
                    f = fopen(path, "wb");
                    if (f) {
                        size_t w = fwrite((void*)vaddr, 1, sz, f);
                        fclose(f);
                        printf("  -> wrote %s (%u bytes, %ux%u NV12) from vaddr=0x%08x\n",
                               path, (unsigned)w, bi[5], bi[6], vaddr);
                        got++;
                    } else printf("  fopen %s failed\n", path);
                } else {
                    printf("  no plausible CPU vaddr (bi[2]=0x%08x bi[0]=0x%08x sz=%u)\n",
                           bi[2], bi[0], sz);
                }
            }
        }
        if (ret_frame) ret_frame(fr);   /* pass frame struct ptr, not index */
    }

    printf("[qcam_probe] captured %d frame(s)\n", got);
    if (preview_stop)   { printf("[qcam_probe] previewStop()\n");   preview_stop(); }
    if (preview_deinit) { printf("[qcam_probe] previewDeInit()\n"); preview_deinit(); }
    dlclose(hal);
    printf("[qcam_probe] done\n");
    return got ? 0 : 3;
}
