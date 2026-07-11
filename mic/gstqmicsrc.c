/*
 * libgstqmicsrc — GStreamer plugin bridging the TouchPad microphone daemon (qmicd) into WPE WebKit's
 * getUserMedia. Mirror of ../camera/gstqcamsrc.c, for AUDIO. Built with the ATLAS toolchain
 * (glibc-2.25 + staging glib/gst 1.20); it does NOT touch ALSA/QDSP — it only reads S16LE PCM
 * chunks from qmicd's shared-memory ring over a unix socket (qmicd owns the media-server recording
 * that actually clocks the DMIC; see mic/README.md).
 *
 * Three GObject types:
 *   - qmicsrc            : GstPushSrc; connects to qmicd (starting the recording), pushes S16LE buffers.
 *   - GstQmicDevice      : GstDevice; create_element() -> qmicsrc; class "Audio/Source".
 *   - GstQmicDevProvider : GstDeviceProvider (klass "Source/Audio"); probe() -> one "TouchPad Microphone".
 *
 * WebKit's GStreamerCaptureDeviceManager runs a GstDeviceMonitor filtered on "Audio/Source", so this
 * provider is discovered with NO WebKit rebuild (deploy plugin + clear gst registry).
 *
 * KEY DIFFERENCE vs qcamsrc: audio is a continuous stream, so we read chunks strictly FIFO (one per
 * create) — NEVER drop-to-newest like the camera (dropping PCM = clicks/gaps). qmicd produces chunks
 * at real-time 16k pace and WebKit's Opus encoder consumes at the same rate, so the socket never backs up.
 */
#include <gst/gst.h>
#include <gst/base/gstpushsrc.h>
#include <gst/audio/audio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#define QMICD_SHM   "/tmp/qmicd.shm"
#define QMICD_SOCK  "/tmp/qmicd.sock"
#define QMICD_MAGIC 0x44494d51u        /* 'QMID' — must match qmicd.c */
#define SLOT0_OFF   4096u
/* Must match qmicd.c exactly (shm slot layout is SLOT0_OFF + slot*CHUNK_BYTES). */
#define MIC_RATE    16000
#define MIC_CH      1
#define CHUNK_BYTES ((MIC_RATE*MIC_CH*2*20)/1000)   /* 20 ms S16LE mono = 640 B */
#define NUM_SLOTS   8
#define CHUNK_NS    (GST_SECOND/(1000/20))          /* 20 ms in ns */

struct qmicd_hdr { guint32 magic, rate, channels, fmt, chunk_bytes, num_slots, seq, pad; };
struct chunk_msg { guint32 seq, slot; };

GST_DEBUG_CATEGORY_STATIC(qmicsrc_debug);
#define GST_CAT_DEFAULT qmicsrc_debug

/* ------------------------------------------------------------------ qmicsrc element */

#define GST_TYPE_QMIC_SRC (gst_qmic_src_get_type())
G_DECLARE_FINAL_TYPE(GstQmicSrc, gst_qmic_src, GST, QMIC_SRC, GstPushSrc)

struct _GstQmicSrc {
    GstPushSrc parent;
    int      sockfd;
    guint8  *shm;
    gsize    shm_sz;
};
G_DEFINE_TYPE(GstQmicSrc, gst_qmic_src, GST_TYPE_PUSH_SRC)

static GstStaticPadTemplate qmic_src_template = GST_STATIC_PAD_TEMPLATE("src",
    GST_PAD_SRC, GST_PAD_ALWAYS,
    GST_STATIC_CAPS("audio/x-raw, format=(string)S16LE, layout=(string)interleaved, "
                    "rate=(int)16000, channels=(int)1"));

/* Caps are already fully fixed in the template; assert them so a downstream converter never
 * second-guesses the layout (mirror qcamsrc's explicit fixate). */
static GstCaps *gst_qmic_src_fixate(GstBaseSrc *base, GstCaps *caps)
{
    GstStructure *s;
    caps = gst_caps_make_writable(caps);
    s = gst_caps_get_structure(caps, 0);
    gst_structure_fixate_field_string(s, "format", "S16LE");
    gst_structure_fixate_field_string(s, "layout", "interleaved");
    gst_structure_fixate_field_nearest_int(s, "rate", MIC_RATE);
    gst_structure_fixate_field_nearest_int(s, "channels", MIC_CH);
    return GST_BASE_SRC_CLASS(gst_qmic_src_parent_class)->fixate(base, caps);
}

static gboolean gst_qmic_src_start(GstBaseSrc *base)
{
    GstQmicSrc *self = GST_QMIC_SRC(base);
    struct sockaddr_un addr;
    int fd, shm_fd;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { GST_ERROR_OBJECT(self, "socket: %s", g_strerror(errno)); return FALSE; }
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    g_strlcpy(addr.sun_path, QMICD_SOCK, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        GST_ERROR_OBJECT(self, "connect %s: %s (is qmicd running?)", QMICD_SOCK, g_strerror(errno));
        close(fd);
        return FALSE;
    }
    shm_fd = open(QMICD_SHM, O_RDONLY);
    if (shm_fd < 0) { GST_ERROR_OBJECT(self, "open shm: %s", g_strerror(errno)); close(fd); return FALSE; }
    self->shm_sz = SLOT0_OFF + (gsize)NUM_SLOTS * CHUNK_BYTES;
    self->shm = mmap(NULL, self->shm_sz, PROT_READ, MAP_SHARED, shm_fd, 0);
    close(shm_fd);
    if (self->shm == MAP_FAILED) { GST_ERROR_OBJECT(self, "mmap shm failed"); self->shm = NULL; close(fd); return FALSE; }
    self->sockfd = fd;
    GST_INFO_OBJECT(self, "connected to qmicd; mic recording starting");
    return TRUE;
}

static gboolean gst_qmic_src_stop(GstBaseSrc *base)
{
    GstQmicSrc *self = GST_QMIC_SRC(base);
    if (self->sockfd >= 0) { close(self->sockfd); self->sockfd = -1; }   /* disconnect -> daemon stops recording */
    if (self->shm && self->shm != MAP_FAILED) { munmap(self->shm, self->shm_sz); self->shm = NULL; }
    GST_INFO_OBJECT(self, "disconnected from qmicd; mic stopped");
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

static GstFlowReturn gst_qmic_src_create(GstPushSrc *push, GstBuffer **out)
{
    GstQmicSrc *self = GST_QMIC_SRC(push);
    struct qmicd_hdr *hdr;
    struct chunk_msg msg;
    GstBuffer *buf;
    guint32 csz, seq_after;
    const guint8 *src;
    int tries;

    if (self->sockfd < 0 || !self->shm) return GST_FLOW_ERROR;
    hdr = (struct qmicd_hdr*)self->shm;

    /* FIFO: exactly one chunk per create — audio must stay gapless (no drop-to-newest). */
    for (tries = 0; tries < 4; tries++) {
        if (!read_full(self->sockfd, &msg, sizeof(msg))) {
            GST_INFO_OBJECT(self, "qmicd closed connection -> EOS");
            return GST_FLOW_EOS;
        }
        if (hdr->magic != QMICD_MAGIC) { GST_ERROR_OBJECT(self, "bad shm magic"); return GST_FLOW_ERROR; }
        csz = hdr->chunk_bytes;
        if (!csz || csz > CHUNK_BYTES || msg.slot >= hdr->num_slots) {
            GST_ERROR_OBJECT(self, "bad chunk meta (csz=%u slot=%u)", csz, msg.slot);
            return GST_FLOW_ERROR;
        }
        src = self->shm + SLOT0_OFF + (gsize)msg.slot * CHUNK_BYTES;
        buf = gst_buffer_new_allocate(NULL, csz, NULL);
        if (!buf) return GST_FLOW_ERROR;
        gst_buffer_fill(buf, 0, src, csz);      /* copy out promptly: slot may be reused by daemon */

        /* Seqlock guard: if qmicd advanced by >= num_slots since our chunk's seq, it wrapped back
         * onto msg.slot and may have overwritten it mid-copy -> torn chunk; retry with a fresh one. */
        seq_after = hdr->seq;
        if (seq_after - msg.seq < hdr->num_slots)
            break;                              /* slot intact -> good chunk */
        gst_buffer_unref(buf);
        GST_DEBUG_OBJECT(self, "slot %u recycled during copy (seq %u->%u), retrying",
                         msg.slot, msg.seq, seq_after);
    }
    if (tries == 4) return GST_FLOW_ERROR;

    GST_BUFFER_DURATION(buf) = CHUNK_NS;         /* 20 ms; basesrc do_timestamp stamps PTS by arrival */
    *out = buf;
    return GST_FLOW_OK;
}

static void gst_qmic_src_init(GstQmicSrc *self)
{
    self->sockfd = -1;
    self->shm = NULL;
    gst_base_src_set_live(GST_BASE_SRC(self), TRUE);          /* real-time mic = live source */
    gst_base_src_set_format(GST_BASE_SRC(self), GST_FORMAT_TIME);
    gst_base_src_set_do_timestamp(GST_BASE_SRC(self), TRUE);
}

static void gst_qmic_src_class_init(GstQmicSrcClass *klass)
{
    GstElementClass *ec = GST_ELEMENT_CLASS(klass);
    GstBaseSrcClass *bc = GST_BASE_SRC_CLASS(klass);
    GstPushSrcClass *pc = GST_PUSH_SRC_CLASS(klass);

    gst_element_class_add_static_pad_template(ec, &qmic_src_template);
    gst_element_class_set_static_metadata(ec, "TouchPad Microphone Source", "Source/Audio",
        "Reads S16LE PCM from the qmicd microphone daemon", "Atlas");
    bc->start  = gst_qmic_src_start;
    bc->stop   = gst_qmic_src_stop;
    bc->fixate = gst_qmic_src_fixate;
    pc->create = gst_qmic_src_create;
}

/* ------------------------------------------------------------------ GstQmicDevice */

#define GST_TYPE_QMIC_DEVICE (gst_qmic_device_get_type())
G_DECLARE_FINAL_TYPE(GstQmicDevice, gst_qmic_device, GST, QMIC_DEVICE, GstDevice)
struct _GstQmicDevice { GstDevice parent; };
G_DEFINE_TYPE(GstQmicDevice, gst_qmic_device, GST_TYPE_DEVICE)

static GstElement *gst_qmic_device_create_element(GstDevice *device, const gchar *name)
{
    (void)device;
    return GST_ELEMENT(g_object_new(GST_TYPE_QMIC_SRC, "name", name, NULL));
}
static void gst_qmic_device_init(GstQmicDevice *self) { (void)self; }
static void gst_qmic_device_class_init(GstQmicDeviceClass *klass)
{
    GST_DEVICE_CLASS(klass)->create_element = gst_qmic_device_create_element;
}

static GstDevice *gst_qmic_device_new(void)
{
    GstCaps *caps = gst_caps_new_simple("audio/x-raw",
        "format",   G_TYPE_STRING, "S16LE",
        "layout",   G_TYPE_STRING, "interleaved",
        "rate",     G_TYPE_INT, MIC_RATE,
        "channels", G_TYPE_INT, MIC_CH, NULL);
    GstStructure *props = gst_structure_new("qmic-proplist",
        "node.name", G_TYPE_STRING, "touchpad-mic",
        "is-default", G_TYPE_BOOLEAN, TRUE, NULL);
    GstDevice *dev = g_object_new(GST_TYPE_QMIC_DEVICE,
        "display-name", "TouchPad Microphone",
        "device-class", "Audio/Source",
        "caps", caps,
        "properties", props, NULL);
    gst_caps_unref(caps);
    gst_structure_free(props);
    return dev;
}

/* ------------------------------------------------------------------ GstQmicDeviceProvider */

#define GST_TYPE_QMIC_DEV_PROVIDER (gst_qmic_dev_provider_get_type())
G_DECLARE_FINAL_TYPE(GstQmicDevProvider, gst_qmic_dev_provider, GST, QMIC_DEV_PROVIDER, GstDeviceProvider)
struct _GstQmicDevProvider { GstDeviceProvider parent; };
G_DEFINE_TYPE(GstQmicDevProvider, gst_qmic_dev_provider, GST_TYPE_DEVICE_PROVIDER)

static GList *gst_qmic_dev_provider_probe(GstDeviceProvider *provider)
{
    (void)provider;
    return g_list_append(NULL, gst_qmic_device_new());
}
static void gst_qmic_dev_provider_init(GstQmicDevProvider *self) { (void)self; }
static void gst_qmic_dev_provider_class_init(GstQmicDevProviderClass *klass)
{
    GstDeviceProviderClass *pc = GST_DEVICE_PROVIDER_CLASS(klass);
    pc->probe = gst_qmic_dev_provider_probe;
    gst_device_provider_class_set_static_metadata(pc, "TouchPad Microphone Device Provider",
        "Source/Audio", "Lists the TouchPad microphone exposed by qmicd", "Atlas");
}

/* ------------------------------------------------------------------ plugin */

static gboolean plugin_init(GstPlugin *plugin)
{
    GST_DEBUG_CATEGORY_INIT(qmicsrc_debug, "qmicsrc", 0, "TouchPad microphone source");
    if (!gst_element_register(plugin, "qmicsrc", GST_RANK_NONE, GST_TYPE_QMIC_SRC))
        return FALSE;
    if (!gst_device_provider_register(plugin, "qmicdeviceprovider", GST_RANK_PRIMARY, GST_TYPE_QMIC_DEV_PROVIDER))
        return FALSE;
    return TRUE;
}

#ifndef PACKAGE
#define PACKAGE "qmicsrc"
#endif
GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, qmicsrc,
    "TouchPad microphone source (via qmicd)", plugin_init, "1.0", "LGPL", "atlas", "https://webos.org")
