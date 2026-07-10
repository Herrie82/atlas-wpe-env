/* gstqcam_test — mirrors WebKit's capture-device discovery: run a GstDeviceMonitor filtered on
 * "Video/Source", find our device, create its element, capture N frames to /tmp/qcam_gst.nv12.
 * Build: atlas gcc125 against staging gst. Run under atlas ld with GST_PLUGIN_PATH set + qcamd running. */
#include <gst/gst.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    GstDeviceMonitor *mon;
    GList *devs, *l;
    GstDevice *chosen = NULL;
    GstElement *pipeline, *src, *sink;
    GstBus *bus;
    GstMessage *msg;
    int nframes = (argc > 1) ? atoi(argv[1]) : 8;

    gst_init(&argc, &argv);

    /* --- device enumeration (what WebKit's GStreamerCaptureDeviceManager does) --- */
    mon = gst_device_monitor_new();
    gst_device_monitor_add_filter(mon, "Video/Source", NULL);
    if (!gst_device_monitor_start(mon)) { g_printerr("monitor start failed\n"); return 1; }
    devs = gst_device_monitor_get_devices(mon);
    g_print("== Video/Source devices ==\n");
    for (l = devs; l; l = l->next) {
        GstDevice *d = GST_DEVICE(l->data);
        gchar *name = gst_device_get_display_name(d);
        gchar *klass = gst_device_get_device_class(d);
        GstCaps *caps = gst_device_get_caps(d);
        gchar *capss = caps ? gst_caps_to_string(caps) : g_strdup("(none)");
        g_print("  device: '%s'  class='%s'  caps=%s\n", name, klass, capss);
        if (g_strrstr(name, "TouchPad")) chosen = gst_object_ref(d);
        g_free(name); g_free(klass); g_free(capss); if (caps) gst_caps_unref(caps);
    }
    g_list_free_full(devs, gst_object_unref);
    if (!chosen) { g_printerr("TouchPad device NOT enumerated\n"); return 2; }
    g_print("== chosen TouchPad device; creating element ==\n");

    /* --- create element from device (what WebKit's GStreamerCapturer::createSource does) --- */
    src = gst_device_create_element(chosen, "cam");
    if (!src) { g_printerr("create_element failed\n"); return 3; }
    g_object_set(src, "num-buffers", nframes, NULL);   /* GstBaseSrc: stop after N -> EOS */

    pipeline = gst_pipeline_new("p");
    sink = gst_element_factory_make("filesink", "sink");
    g_object_set(sink, "location", "/tmp/qcam_gst.nv12", NULL);
    gst_bin_add_many(GST_BIN(pipeline), src, sink, NULL);
    if (!gst_element_link(src, sink)) { g_printerr("link failed\n"); return 4; }

    g_print("== PLAYING (capturing %d frames) ==\n", nframes);
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    bus = gst_element_get_bus(pipeline);
    msg = gst_bus_timed_pop_filtered(bus, 15 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    if (!msg) g_print("  TIMEOUT (no EOS in 15s)\n");
    else if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
        GError *err = NULL; gchar *dbg = NULL;
        gst_message_parse_error(msg, &err, &dbg);
        g_printerr("  ERROR: %s (%s)\n", err->message, dbg ? dbg : "");
        g_error_free(err); g_free(dbg);
    } else g_print("  EOS -> capture complete\n");
    if (msg) gst_message_unref(msg);

    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(bus); gst_object_unref(pipeline);
    gst_device_monitor_stop(mon); gst_object_unref(mon);
    g_print("== done ==\n");
    return 0;
}
