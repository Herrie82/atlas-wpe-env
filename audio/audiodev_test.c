/* List Audio/Source devices via GstDeviceMonitor -- proves the mic enumerates (what WebKit does). */
#include <gst/gst.h>
#include <stdio.h>
int main(int argc, char **argv) {
    gst_init(&argc, &argv);
    GstDeviceMonitor *mon = gst_device_monitor_new();
    gst_device_monitor_add_filter(mon, "Audio/Source", NULL);
    if (!gst_device_monitor_start(mon)) { g_printerr("monitor start FAILED\n"); return 1; }
    GList *devs = gst_device_monitor_get_devices(mon), *l;
    int n = 0;
    for (l = devs; l; l = l->next) {
        GstDevice *d = GST_DEVICE(l->data);
        gchar *name = gst_device_get_display_name(d);
        gchar *cls  = gst_device_get_device_class(d);
        GstCaps *caps = gst_device_get_caps(d);
        gchar *cs = caps ? gst_caps_to_string(caps) : g_strdup("(none)");
        g_print("[%d] class=%s name=\"%s\"\n     caps=%.160s\n", n++, cls, name, cs);
        g_free(name); g_free(cls); g_free(cs); if (caps) gst_caps_unref(caps);
    }
    g_print("== %d Audio/Source device(s) ==\n", n);
    g_list_free_full(devs, gst_object_unref);
    return 0;
}
