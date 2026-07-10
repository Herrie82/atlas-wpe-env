/* gstqcam_conv_test — reproduce WebKit's conversion locally:
 *   qcamsrc ! videoconvert ! video/x-raw,format=BGRA ! filesink
 * If the output BGRA shows the green/pink bottom-half garbage, the bug is videoconvert reading our
 * NV12 UV plane at the wrong offset (plane-layout mismatch), reproducible without the browser.
 * Build: atlas gcc125. Run under atlas ld with GST_PLUGIN_PATH + qcamd running (browser stopped). */
#include <gst/gst.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    GstDeviceMonitor *mon; GList *devs, *l; GstDevice *chosen = NULL;
    GstElement *pipeline, *src, *conv, *capsf, *sink; GstBus *bus; GstMessage *msg;
    GstCaps *ocaps;
    int nframes = (argc > 1) ? atoi(argv[1]) : 10;

    gst_init(&argc, &argv);
    mon = gst_device_monitor_new();
    gst_device_monitor_add_filter(mon, "Video/Source", NULL);
    if (!gst_device_monitor_start(mon)) { g_printerr("monitor start failed\n"); return 1; }
    devs = gst_device_monitor_get_devices(mon);
    for (l = devs; l; l = l->next) {
        GstDevice *d = GST_DEVICE(l->data);
        gchar *name = gst_device_get_display_name(d);
        if (g_strrstr(name, "TouchPad")) chosen = gst_object_ref(d);
        g_free(name);
    }
    g_list_free_full(devs, gst_object_unref);
    if (!chosen) { g_printerr("TouchPad device NOT enumerated\n"); return 2; }

    src = gst_device_create_element(chosen, "cam");
    g_object_set(src, "num-buffers", nframes, NULL);
    conv = gst_element_factory_make("videoconvert", "conv");
    capsf = gst_element_factory_make("capsfilter", "capsf");
    ocaps = gst_caps_from_string("video/x-raw,format=BGRA,width=640,height=480");
    g_object_set(capsf, "caps", ocaps, NULL); gst_caps_unref(ocaps);
    sink = gst_element_factory_make("filesink", "sink");
    g_object_set(sink, "location", "/tmp/qcam_conv.bgra", NULL);

    pipeline = gst_pipeline_new("p");
    gst_bin_add_many(GST_BIN(pipeline), src, conv, capsf, sink, NULL);
    if (!gst_element_link_many(src, conv, capsf, sink, NULL)) { g_printerr("link failed\n"); return 4; }

    g_print("== PLAYING (convert %d frames -> BGRA) ==\n", nframes);
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    bus = gst_element_get_bus(pipeline);
    msg = gst_bus_timed_pop_filtered(bus, 15 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
    if (!msg) g_print("  TIMEOUT\n");
    else if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
        GError *err = NULL; gchar *dbg = NULL; gst_message_parse_error(msg, &err, &dbg);
        g_printerr("  ERROR: %s (%s)\n", err->message, dbg ? dbg : ""); g_error_free(err); g_free(dbg);
    } else g_print("  EOS -> /tmp/qcam_conv.bgra (last of %d frames)\n", nframes);
    if (msg) gst_message_unref(msg);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    return 0;
}
