/*
 * libgstqcamsrc — GStreamer plugin bridging the TouchPad camera daemon (qcamd) into WPE WebKit's
 * getUserMedia. Built with the ATLAS toolchain (glibc-2.25 + staging glib/gst 1.20); it does NOT
 * touch libqcameralib (which hangs in that runtime) — it only reads NV12 frames from qcamd's
 * shared-memory ring over a unix socket.
 *
 * Three GObject types:
 *   - qcamsrc            : GstPushSrc; connects to qcamd (starting the camera), pushes NV12 buffers.
 *   - GstQcamDevice      : GstDevice; create_element() -> qcamsrc; class "Video/Source".
 *   - GstQcamDevProvider : GstDeviceProvider (klass "Source/Video"); probe() -> one "TouchPad Front Camera".
 *
 * WebKit's GStreamerCaptureDeviceManager runs a GstDeviceMonitor with add_filter("Video/Source"),
 * so this provider is discovered with NO WebKit rebuild (deploy plugin + clear gst registry).
 */
#include <gst/gst.h>
#include <gst/base/gstpushsrc.h>
#include <gst/video/video.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#define QCAMD_SHM   "/tmp/qcamd.shm"
#define QCAMD_SOCK  "/tmp/qcamd.sock"
#define QCAMD_MAGIC 0x4d414351u
#define SLOT0_OFF   4096u
#define MAX_FRAME   (1280*1024*2)
#define CAM_W 640
#define CAM_H 480

struct qcamd_hdr { guint32 magic, width, height, fourcc, frame_size, num_slots, seq, pad; };
struct frame_msg { guint32 seq, slot; };

GST_DEBUG_CATEGORY_STATIC(qcamsrc_debug);
#define GST_CAT_DEFAULT qcamsrc_debug

/* ------------------------------------------------------------------ qcamsrc element */

#define GST_TYPE_QCAM_SRC (gst_qcam_src_get_type())
G_DECLARE_FINAL_TYPE(GstQcamSrc, gst_qcam_src, GST, QCAM_SRC, GstPushSrc)

struct _GstQcamSrc {
    GstPushSrc parent;
    int        sockfd;
    guint8    *shm;
    gsize      shm_sz;
};
G_DEFINE_TYPE(GstQcamSrc, gst_qcam_src, GST_TYPE_PUSH_SRC)

static GstStaticPadTemplate qcam_src_template = GST_STATIC_PAD_TEMPLATE("src",
    GST_PAD_SRC, GST_PAD_ALWAYS,
    GST_STATIC_CAPS("video/x-raw, format=(string)NV12, "
                    "width=(int)640, height=(int)480, framerate=(fraction)[0/1, 30/1]"));

static gboolean gst_qcam_src_start(GstBaseSrc *base)
{
    GstQcamSrc *self = GST_QCAM_SRC(base);
    struct sockaddr_un addr;
    int fd, shm_fd;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { GST_ERROR_OBJECT(self, "socket: %s", g_strerror(errno)); return FALSE; }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    g_strlcpy(addr.sun_path, QCAMD_SOCK, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        GST_ERROR_OBJECT(self, "connect %s: %s (is qcamd running?)", QCAMD_SOCK, g_strerror(errno));
        close(fd);
        return FALSE;
    }
    shm_fd = open(QCAMD_SHM, O_RDONLY);
    if (shm_fd < 0) { GST_ERROR_OBJECT(self, "open shm: %s", g_strerror(errno)); close(fd); return FALSE; }
    self->shm_sz = SLOT0_OFF + (gsize)4 * MAX_FRAME;
    self->shm = mmap(NULL, self->shm_sz, PROT_READ, MAP_SHARED, shm_fd, 0);
    close(shm_fd);
    if (self->shm == MAP_FAILED) { GST_ERROR_OBJECT(self, "mmap shm failed"); self->shm = NULL; close(fd); return FALSE; }
    self->sockfd = fd;
    GST_INFO_OBJECT(self, "connected to qcamd; camera starting");
    return TRUE;
}

static gboolean gst_qcam_src_stop(GstBaseSrc *base)
{
    GstQcamSrc *self = GST_QCAM_SRC(base);
    if (self->sockfd >= 0) { close(self->sockfd); self->sockfd = -1; }   /* disconnect -> daemon stops camera */
    if (self->shm && self->shm != MAP_FAILED) { munmap(self->shm, self->shm_sz); self->shm = NULL; }
    GST_INFO_OBJECT(self, "disconnected from qcamd; camera stopped");
    return TRUE;
}

/* blocking read of exactly n bytes */
static gboolean read_full(int fd, void *buf, gsize n)
{
    guint8 *p = buf; gsize got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return FALSE; }
        got += (gsize)r;
    }
    return TRUE;
}

/* Drain the socket to the newest queued {seq,slot}. Returns FALSE only on a closed connection.
 * WebKit consumes frames slower than qcamd produces them, so the 8-byte messages back up in the
 * socket queue. Processing them FIFO makes us read ever-older slots which qcamd has meanwhile
 * recycled and is mid-overwriting -> a torn frame (Y fully rewritten, bottom UV still stale =
 * green/pink). Always jump to the freshest frame: qcamd just finished writing that slot and won't
 * touch it again for num_slots frames, far longer than our microsecond copy takes. */
static gboolean drain_to_newest(int fd, struct frame_msg *msg)
{
    if (!read_full(fd, msg, sizeof(*msg))) return FALSE;   /* first: block for at least one */
    for (;;) {
        struct frame_msg m2;
        ssize_t r = recv(fd, &m2, sizeof(m2), MSG_DONTWAIT);
        if (r == (ssize_t)sizeof(m2)) { *msg = m2; continue; } /* keep the newer one */
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break; /* queue empty */
        if (r <= 0) break;                                     /* closed/error: use what we have */
        /* partial message mid-delivery: finish it (blocking), then keep draining */
        if (!read_full(fd, ((guint8*)&m2) + r, sizeof(m2) - (gsize)r)) return FALSE;
        *msg = m2;
    }
    return TRUE;
}

static GstFlowReturn gst_qcam_src_create(GstPushSrc *push, GstBuffer **out)
{
    GstQcamSrc *self = GST_QCAM_SRC(push);
    struct qcamd_hdr *hdr;
    struct frame_msg msg;
    GstBuffer *buf;
    guint32 fsz;
    const guint8 *src;
    int tries;

    if (self->sockfd < 0 || !self->shm) return GST_FLOW_ERROR;
    hdr = (struct qcamd_hdr*)self->shm;

    for (tries = 0; tries < 4; tries++) {
        guint32 seq_after;
        if (!drain_to_newest(self->sockfd, &msg)) {
            GST_INFO_OBJECT(self, "qcamd closed connection -> EOS");
            return GST_FLOW_EOS;
        }
        if (hdr->magic != QCAMD_MAGIC) { GST_ERROR_OBJECT(self, "bad shm magic"); return GST_FLOW_ERROR; }
        fsz = hdr->frame_size;
        if (!fsz || fsz > MAX_FRAME || msg.slot >= hdr->num_slots) { GST_ERROR_OBJECT(self, "bad frame meta"); return GST_FLOW_ERROR; }

        src = self->shm + SLOT0_OFF + (gsize)msg.slot * MAX_FRAME;
        buf = gst_buffer_new_allocate(NULL, fsz, NULL);
        if (!buf) return GST_FLOW_ERROR;
        gst_buffer_fill(buf, 0, src, fsz);      /* copy out promptly: slot may be reused by daemon */

        /* Seqlock guard: if qcamd has advanced by >= num_slots since our frame's seq, it wrapped
         * back onto msg.slot and may have overwritten it mid-copy -> torn frame; retry. */
        seq_after = hdr->seq;
        if (seq_after - msg.seq < hdr->num_slots)
            break;                              /* slot still intact -> good frame */
        gst_buffer_unref(buf);
        GST_DEBUG_OBJECT(self, "slot %u recycled during copy (seq %u->%u), retrying",
                         msg.slot, msg.seq, seq_after);
    }
    if (tries == 4) return GST_FLOW_ERROR;      /* persistently torn (shouldn't happen) */

    /* Stamp the exact (tight) NV12 plane layout so a downstream converter doesn't assume its own
     * aligned UV-plane offset. Y stride=640 @0, UV stride=640 @307200 (tight). */
    gst_buffer_add_video_meta(buf, GST_VIDEO_FRAME_FLAG_NONE,
                              GST_VIDEO_FORMAT_NV12, CAM_W, CAM_H);
    *out = buf;
    return GST_FLOW_OK;
}

static void gst_qcam_src_init(GstQcamSrc *self)
{
    self->sockfd = -1;
    self->shm = NULL;
    gst_base_src_set_live(GST_BASE_SRC(self), TRUE);
    gst_base_src_set_format(GST_BASE_SRC(self), GST_FORMAT_TIME);
    gst_base_src_set_do_timestamp(GST_BASE_SRC(self), TRUE);
}

static void gst_qcam_src_class_init(GstQcamSrcClass *klass)
{
    GstElementClass *ec = GST_ELEMENT_CLASS(klass);
    GstBaseSrcClass *bc = GST_BASE_SRC_CLASS(klass);
    GstPushSrcClass *pc = GST_PUSH_SRC_CLASS(klass);

    gst_element_class_add_static_pad_template(ec, &qcam_src_template);
    gst_element_class_set_static_metadata(ec, "TouchPad Camera Source", "Source/Video",
        "Reads NV12 frames from the qcamd camera daemon", "Atlas");
    bc->start = gst_qcam_src_start;
    bc->stop  = gst_qcam_src_stop;
    pc->create = gst_qcam_src_create;
}

/* ------------------------------------------------------------------ GstQcamDevice */

#define GST_TYPE_QCAM_DEVICE (gst_qcam_device_get_type())
G_DECLARE_FINAL_TYPE(GstQcamDevice, gst_qcam_device, GST, QCAM_DEVICE, GstDevice)
struct _GstQcamDevice { GstDevice parent; };
G_DEFINE_TYPE(GstQcamDevice, gst_qcam_device, GST_TYPE_DEVICE)

/* Return a bin [ qcamsrc(NV12 640x480) ! videoflip clockwise ] so the portrait-mounted sensor shows
 * upright when the device is held in landscape (raw frame has the subject's head to the left; a 90°
 * clockwise rotation stands it up -> 480x640). The frames stay linear NV12, so the (gated) mdpdetile
 * de-tiler is still correctly skipped and the GL sink path is preserved.
 * NOTE: no horizontal mirror -- getUserMedia delivers the true (un-mirrored) stream; a selfie preview
 * is mirrored by the page via CSS, and WebRTC/test sites expect the raw stream. */
static GstElement *gst_qcam_device_create_element(GstDevice *device, const gchar *name)
{
    GstElement *bin, *src, *flip;
    GstPad *srcpad;
    (void)device;

    src = GST_ELEMENT(g_object_new(GST_TYPE_QCAM_SRC, "name", "qcamrawsrc", NULL));
    bin = gst_bin_new(name);
    flip = gst_element_factory_make("videoflip", "qcamflip");
    if (!bin || !flip) {                         /* degrade to un-rotated raw source */
        if (bin) gst_object_unref(bin);
        if (flip) gst_object_unref(flip);
        return src;
    }
    g_object_set(flip, "method", 1 /* GST_VIDEO_FLIP_METHOD_90R = clockwise */, NULL);
    gst_bin_add_many(GST_BIN(bin), src, flip, NULL);
    if (!gst_element_link(src, flip)) {
        gst_object_unref(bin);
        return GST_ELEMENT(g_object_new(GST_TYPE_QCAM_SRC, "name", name, NULL));
    }
    srcpad = gst_element_get_static_pad(flip, "src");
    gst_element_add_pad(bin, gst_ghost_pad_new("src", srcpad));
    gst_object_unref(srcpad);
    return bin;
}
static void gst_qcam_device_init(GstQcamDevice *self) { (void)self; }
static void gst_qcam_device_class_init(GstQcamDeviceClass *klass)
{
    GST_DEVICE_CLASS(klass)->create_element = gst_qcam_device_create_element;
}

static GstDevice *gst_qcam_device_new(void)
{
    /* Advertise the POST-rotation geometry (create_element rotates 90deg CW -> portrait). */
    GstCaps *caps = gst_caps_new_simple("video/x-raw",
        "format", G_TYPE_STRING, "NV12",
        "width",  G_TYPE_INT, CAM_H,   /* 480 */
        "height", G_TYPE_INT, CAM_W,   /* 640 */
        "framerate", GST_TYPE_FRACTION, 15, 1, NULL);
    GstStructure *props = gst_structure_new("qcam-proplist",
        "node.name", G_TYPE_STRING, "touchpad-front",
        "is-default", G_TYPE_BOOLEAN, TRUE, NULL);
    GstDevice *dev = g_object_new(GST_TYPE_QCAM_DEVICE,
        "display-name", "TouchPad Front Camera",
        "device-class", "Video/Source",
        "caps", caps,
        "properties", props, NULL);
    gst_caps_unref(caps);
    gst_structure_free(props);
    return dev;
}

/* ------------------------------------------------------------------ GstQcamDeviceProvider */

#define GST_TYPE_QCAM_DEV_PROVIDER (gst_qcam_dev_provider_get_type())
G_DECLARE_FINAL_TYPE(GstQcamDevProvider, gst_qcam_dev_provider, GST, QCAM_DEV_PROVIDER, GstDeviceProvider)
struct _GstQcamDevProvider { GstDeviceProvider parent; };
G_DEFINE_TYPE(GstQcamDevProvider, gst_qcam_dev_provider, GST_TYPE_DEVICE_PROVIDER)

static GList *gst_qcam_dev_provider_probe(GstDeviceProvider *provider)
{
    (void)provider;
    return g_list_append(NULL, gst_qcam_device_new());
}
static void gst_qcam_dev_provider_init(GstQcamDevProvider *self) { (void)self; }
static void gst_qcam_dev_provider_class_init(GstQcamDevProviderClass *klass)
{
    GstDeviceProviderClass *pc = GST_DEVICE_PROVIDER_CLASS(klass);
    pc->probe = gst_qcam_dev_provider_probe;
    gst_device_provider_class_set_static_metadata(pc, "TouchPad Camera Device Provider",
        "Source/Video", "Lists the TouchPad front camera exposed by qcamd", "Atlas");
}

/* ------------------------------------------------------------------ plugin */

static gboolean plugin_init(GstPlugin *plugin)
{
    GST_DEBUG_CATEGORY_INIT(qcamsrc_debug, "qcamsrc", 0, "TouchPad camera source");
    if (!gst_element_register(plugin, "qcamsrc", GST_RANK_NONE, GST_TYPE_QCAM_SRC))
        return FALSE;
    if (!gst_device_provider_register(plugin, "qcamdeviceprovider", GST_RANK_PRIMARY, GST_TYPE_QCAM_DEV_PROVIDER))
        return FALSE;
    return TRUE;
}

#ifndef PACKAGE
#define PACKAGE "qcamsrc"
#endif
GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, qcamsrc,
    "TouchPad camera source (via qcamd)", plugin_init, "1.0", "LGPL", "atlas", "https://webos.org")
