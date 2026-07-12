/* Atlas: GStreamer 1.x audio sink that pipes PCM to the qspkd speaker daemon over a UNIX socket.
 *
 * WHY a socket (not libpulse here): the device PulseAudio is 0.9.22, built for the OLD webOS glibc. Loading
 * the system libpulse into the atlas glibc-2.52 WebProcess SIGSEGVs during the gst plugin scan (verified —
 * it hangs the browser mid-load). So this sink has ZERO pulse/glibc dependency: it just writes raw PCM to
 * /tmp/qspkd.sock. qspkd (a tiny daemon under the SYSTEM glibc, started by the BS wrapper like qcamd) reads
 * that socket and plays via the system pa_simple -> audiod -> speaker. Same split as the mic (qmicd/qmicsrc).
 *
 * PACING: the socket is BLOCKING and qspkd does a BLOCKING pa_simple_write, so when pulse is full qspkd stops
 * reading, the socket backs up, and our send() blocks — natural backpressure, exactly like pa_simple_write did.
 *
 * THREAD-SAFETY (mirrors the old pa_simple sink): GstAudioSink calls ::reset (state-change thread) concurrently
 * with ::write (ringbuffer thread). A GMutex serialises socket access + an atomic `flushing` flag makes the
 * ringbuffer thread DROP writes once teardown starts, so ::reset/::unprepare can close the fd without racing. */
#include <gst/gst.h>
#include <gst/audio/audio.h>
#include <gst/audio/gstaudiosink.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define QSPK_SOCK  "/tmp/qspkd.sock"
#define QSPK_MAGIC 0x5153504bU   /* 'QSPK' */
/* PCM format codes on the wire (kept tiny + explicit so qspkd needn't know gst enums). */
enum { QF_S16LE=0, QF_S16BE=1, QF_F32LE=2, QF_S32LE=3, QF_U8=4 };
struct qspk_hdr { guint32 magic, format, rate, channels; };

#define GST_TYPE_QSPK_SINK (gst_qspk_sink_get_type())
G_DECLARE_FINAL_TYPE(GstQspkSink, gst_qspk_sink, GST, QSPK_SINK, GstAudioSink)

struct _GstQspkSink {
    GstAudioSink parent;
    gint         fd;       /* socket to qspkd, or -1 */
    guint        rate;
    GMutex       lock;     /* serialises ALL socket access across threads */
    gint         flushing; /* atomic: set in reset/unprepare, cleared in prepare */
};

G_DEFINE_TYPE(GstQspkSink, gst_qspk_sink, GST_TYPE_AUDIO_SINK)

static GstStaticPadTemplate sink_tmpl = GST_STATIC_PAD_TEMPLATE(
    "sink", GST_PAD_SINK, GST_PAD_ALWAYS,
    GST_STATIC_CAPS("audio/x-raw, "
        "format = (string) { S16LE, S16BE, F32LE, S32LE, U8 }, "
        "rate = (int) [ 1, MAX ], channels = (int) [ 1, 8 ], "
        "layout = (string) interleaved"));

/* write exactly n bytes to fd (loops over partial sends); returns FALSE on error/close. */
static gboolean send_all(int fd, const void *buf, size_t n)
{
    const char *p = (const char *)buf;
    while (n > 0) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; return FALSE; }
        if (w == 0) return FALSE;
        p += w; n -= (size_t)w;
    }
    return TRUE;
}

static gboolean gst_qspk_sink_open(GstAudioSink *s)  { (void)s; return TRUE; }   /* socket opened lazily in prepare */
static gboolean gst_qspk_sink_close(GstAudioSink *s) { (void)s; return TRUE; }

static gboolean gst_qspk_sink_prepare(GstAudioSink *asink, GstAudioRingBufferSpec *spec)
{
    GstQspkSink *self = GST_QSPK_SINK(asink);
    GstAudioInfo *info = &spec->info;
    guint32 qf;
    switch (GST_AUDIO_INFO_FORMAT(info)) {
        case GST_AUDIO_FORMAT_S16LE: qf = QF_S16LE; break;
        case GST_AUDIO_FORMAT_S16BE: qf = QF_S16BE; break;
        case GST_AUDIO_FORMAT_F32LE: qf = QF_F32LE; break;
        case GST_AUDIO_FORMAT_S32LE: qf = QF_S32LE; break;
        case GST_AUDIO_FORMAT_U8:    qf = QF_U8;    break;
        default: GST_ERROR_OBJECT(self, "unsupported format"); return FALSE;
    }

    g_mutex_lock(&self->lock);
    g_atomic_int_set(&self->flushing, 0);
    self->rate = GST_AUDIO_INFO_RATE(info);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    gboolean ok = FALSE;
    if (fd >= 0) {
        struct sockaddr_un addr; memset(&addr, 0, sizeof addr);
        addr.sun_family = AF_UNIX;
        g_strlcpy(addr.sun_path, QSPK_SOCK, sizeof addr.sun_path);
        if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
            struct qspk_hdr h = { QSPK_MAGIC, qf, self->rate, (guint32)GST_AUDIO_INFO_CHANNELS(info) };
            ok = send_all(fd, &h, sizeof h);
        }
    }
    if (ok) self->fd = fd;
    else if (fd >= 0) close(fd);
    g_mutex_unlock(&self->lock);

    if (!ok) { GST_ERROR_OBJECT(self, "connect/handshake to %s failed: %s", QSPK_SOCK, g_strerror(errno)); return FALSE; }
    GST_INFO_OBJECT(self, "qspkd connected %dch %dHz qf=%u", GST_AUDIO_INFO_CHANNELS(info), self->rate, qf);
    return TRUE;
}

static gboolean gst_qspk_sink_unprepare(GstAudioSink *asink)
{
    GstQspkSink *self = GST_QSPK_SINK(asink);
    g_atomic_int_set(&self->flushing, 1);
    g_mutex_lock(&self->lock);
    if (self->fd >= 0) { close(self->fd); self->fd = -1; }   /* qspkd sees EOF -> drains + waits for next */
    g_mutex_unlock(&self->lock);
    return TRUE;
}

static gint gst_qspk_sink_write(GstAudioSink *asink, gpointer data, guint length)
{
    GstQspkSink *self = GST_QSPK_SINK(asink);
    if (g_atomic_int_get(&self->flushing))
        return (gint)length;   /* teardown in progress: claim consumed, don't block */

    g_mutex_lock(&self->lock);
    if (self->fd < 0) { g_mutex_unlock(&self->lock); return -1; }
    gboolean ok = send_all(self->fd, data, length);   /* blocking -> qspkd/pulse backpressure paces us */
    g_mutex_unlock(&self->lock);

    if (!ok) { GST_ERROR_OBJECT(self, "qspkd write failed: %s", g_strerror(errno)); return -1; }
    return (gint)length;
}

static guint gst_qspk_sink_delay(GstAudioSink *asink) { (void)asink; return 0; }   /* qspkd/pulse buffer the tail; sync-good-enough for calls */

static void gst_qspk_sink_reset(GstAudioSink *asink)
{
    GstQspkSink *self = GST_QSPK_SINK(asink);
    /* Stop feeding: the ringbuffer thread drops writes now, so an in-flight send() drains/errors and returns,
     * letting us take the lock. We DON'T close here (a flushing seek reuses the connection) — just unblock. */
    g_atomic_int_set(&self->flushing, 1);
    g_mutex_lock(&self->lock);
    /* nothing to flush on our side; qspkd keeps its pulse stream. */
    g_mutex_unlock(&self->lock);
    g_atomic_int_set(&self->flushing, 0);
}

static void gst_qspk_sink_finalize(GObject *o)
{
    GstQspkSink *self = GST_QSPK_SINK(o);
    if (self->fd >= 0) { close(self->fd); self->fd = -1; }
    g_mutex_clear(&self->lock);
    G_OBJECT_CLASS(gst_qspk_sink_parent_class)->finalize(o);
}

static void gst_qspk_sink_class_init(GstQspkSinkClass *klass)
{
    GObjectClass *go = G_OBJECT_CLASS(klass);
    GstElementClass *ec = GST_ELEMENT_CLASS(klass);
    GstAudioSinkClass *ac = GST_AUDIO_SINK_CLASS(klass);
    go->finalize = gst_qspk_sink_finalize;
    gst_element_class_add_static_pad_template(ec, &sink_tmpl);
    gst_element_class_set_static_metadata(ec, "Atlas qspkd audio sink", "Sink/Audio",
        "Pipes PCM to the qspkd daemon (system PulseAudio -> audiod -> speaker)", "Atlas");
    ac->open = gst_qspk_sink_open;   ac->close = gst_qspk_sink_close;
    ac->prepare = gst_qspk_sink_prepare;  ac->unprepare = gst_qspk_sink_unprepare;
    ac->write = gst_qspk_sink_write;  ac->delay = gst_qspk_sink_delay;  ac->reset = gst_qspk_sink_reset;
}

static void gst_qspk_sink_init(GstQspkSink *self)
{
    self->fd = -1;
    self->rate = 0;
    g_mutex_init(&self->lock);
    g_atomic_int_set(&self->flushing, 0);
}

static gboolean plugin_init(GstPlugin *plugin)
{
    /* PRIMARY+20 so WebKit's autoaudiosink prefers it over alsasink (whose ALSA 'default' -> pulse plugin is missing). */
    return gst_element_register(plugin, "atlasqspksink", GST_RANK_PRIMARY + 20, GST_TYPE_QSPK_SINK);
}

GST_PLUGIN_DEFINE(GST_VERSION_MAJOR, GST_VERSION_MINOR, atlasqspksink,
    "Atlas qspkd (socket) audio sink", plugin_init, "1.0", "LGPL",
    "atlas", "atlas-browser")
