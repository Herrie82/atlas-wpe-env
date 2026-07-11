# qmicd — TouchPad WebRTC microphone bridge for Atlas

Mirror of the `../camera/` (qcamd / gstqcamsrc) design, for the **microphone**.

**STATUS (2026-07-11): WORKING end-to-end on-device.** `qmicd` + `libgstqmicsrc.so` built
(atlas gcc125), deployed, and the DMIC captures **real audio** — the testclient reported
`64000 bytes, NONZERO=31996 (MIC CAPTURING AUDIO)` via the full chain (captureV3→load→
startAudioCapture→FIFO→shm/socket). qmicd auto-starts from `wrapper-BrowserServer`.
Remaining: confirm WebKit getUserMedia selects "TouchPad Microphone" over its default source.

## Why it's needed (the hard part, fully reverse-engineered)

The TouchPad internal mic is a **digital mic (DMIC)** on the Qualcomm QDSP (WM8994 AIF2).
Facts established by decompiling `audiod` + `mediaserver` (Ghidra) and on-device tests:

- `arecord hw:0` opens the PCM but yields **pure silence** — the DMIC/AIF2 is only
  clocked while a webOS **media-server recording** is active. That recording makes
  `audiod` enable the mic route: `TopazDevice::setRecording` → UCM `_enadev "Force-route.0"`
  **+** libmsm `msm_capture_route(msm_get_device("speaker_mono_tx"),1)`.
- `hw:0` capture is **exclusive** (2nd open = `EBUSY`), so Atlas can't run its own alsasrc.
- The media server captures the mic with plain `alsasrc device=hw:0` — but only *inside*
  a `captureV3` recording session, and it signals `audiod` via a shared-memory
  `EMediaServerCommand` property (not luna).
- **Missing file fix (already deployed, bake into restore):** `msm_media_case`
  (`/usr/share/alsa/ucm/msm-audio/`) — the UCM device defs (incl. `Force-route` + the
  DMIC route `ADCL Mux=1`) — is absent on webOS 3.0.5; copied from the 3.0.6 (doctor306-opal) rootfs.

So qmicd is the **single owner** of the capture, exactly like qcamd for the camera.

## The media-server audio-record API (from `.../frameworks/mediacapture/.../media.js`)

All on ONE persistent LunaService handle (the session is bound to the connection):

1. `captureV3` on `palm://com.palm.mediad/service`, `{"subscribe":true}` →
   reply `location = "palm://com.palm.mediad.MediaCaptureV3_<pid>/"`  *(confirmed on-device)*
2. `<location>load` `{"args":[deviceUri, {"deviceUri":deviceUri}]}`  *(audio input device — see TODO)*
3. `<location>startAudioCapture` `{"args":[FIFO, {"mimetype":"audio/vnd.wave","codecs":"1","samplerate":16000,"bitrate":256000,"duration":0,"size":0}]}`
   → media server: `alsasrc hw:0 ! wavenc ! filesink location=FIFO`, DMIC live.
4. `<location>stopAudioCapture` `{"args":[]}` ; `<location>unload` `{"args":[]}` ; cancel the captureV3 subscription.

Audio formats offered: WAV PCM @ 8000 / 16000 / 44100 Hz.

## Architecture

```
Atlas (WebKit getUserMedia)  --connect-->  qmicd  --LunaService-->  mediaserver --> audiod/QDSP --> DMIC
   libgstqmicsrc.so  <--{seq,slot} sock + shm ring--  qmicd  <--WAV over FIFO--  mediaserver(alsasrc hw:0)
```

- **qmicd.c** (this dir): PalmPDK/glibc-2.8 daemon under the SYSTEM env (like qcamd).
  On Atlas client connect → drives 1–3 above → reads the FIFO, strips the 44-byte WAV
  header, and publishes fixed 20 ms S16LE chunks to `/tmp/qmicd.shm` + `/tmp/qmicd.sock`
  (`{uint32 seq; uint32 slot}`). On disconnect → 4 + release.
- **libgstqmicsrc.so** (TODO, mirror `../camera/gstqcamsrc.c`): GstPushSrc that connects to
  the socket and pushes `audio/x-raw, format=S16LE, rate=16000, channels=1`. WebKit's
  WebRTC pipeline resamples 16k→48k for Opus. Register it as a device provider named
  "TouchPad Microphone" so getUserMedia enumerates it.

## Build / deploy

```
./build.sh                                 # qmicd (PalmPDK) + libgstqmicsrc.so (atlas gcc125, if present)
# deploy:
#   qmicd                        -> deviceroot/atlas/qmicd  (start from wrapper-BrowserServer, SYSTEM env, like qcamd)
#   org.webosports.qmicd.json    -> /usr/share/ls2/roles/{pub,prv}/  (ls-control scan-services or reboot)
#   libgstqmicsrc.so             -> deviceroot/wpe-252/lib/gstreamer-1.0/
#   msm_media_case               -> /usr/share/alsa/ucm/msm-audio/  (rw remount; bake into full-restore-atlas.sh)
```

## Remaining TODOs (device-specific)

- **[load deviceUri]** empty `""` was rejected on-device (`returnValue:false`). Parse the
  audio-input `deviceUri` from the `captureV3` subscription's device-list updates
  (`cb_captureV3` in qmicd.c) and fill `AUDIO_DEVICE_URI`.
- **[role/appId]** the session rejected calls from `com.palm.test` ("AppId msg type 17").
  Ensure the `org.webosports.qmicd` role grants outbound to `com.palm.mediad.MediaCaptureV3_*`
  and that all calls ride the one `LSRegister` handle (they do in qmicd.c).
- **[WAV header]** `wavenc` streaming header is 44 bytes; verify (qmicd skips 44). If wavenc
  emits a different header size on a FIFO, adjust `WAV_HDR`, or request a raw format if one exists.
- **[gstqmicsrc.c]** ✅ DONE — written (mirror of gstqcamsrc.c; audio caps `S16LE,16000,1`,
  chunk_msg, FIFO not drop-to-newest, provider "TouchPad Microphone" klass "Source/Audio").
  Compiles clean vs the atlas gcc125 + staging gst-1.20. Registers a device provider filtered
  on "Audio/Source" so WebKit's GStreamerCaptureDeviceManager enumerates it with no WebKit rebuild.
- **[wire-in]** hook WebKit `RealtimeOutgoingAudioSourceGStreamer` / the getUserMedia audio
  capturer to use `qmicsrc` (mirror how the camera path uses `qcamsrc`). Likely just: deploy the
  plugin + clear the gst registry so the device provider is discovered (as with the camera).

See memory `atlas-webrtc-receiver-muted` for the full decompiled stack.
