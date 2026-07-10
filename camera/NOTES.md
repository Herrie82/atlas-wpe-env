# Camera Path A — 2.6.35 V4L2 node for mt9m113 (Atlas getUserMedia)

Live kernel tree: /home/herrie/Documents/GitHub/webos-uber-kernel  (builds device #9, Jul 5)
Camera dir: drivers/media/video/msm/
Device: 2.6.35-palm-tenderloin, mt9m113 inits at boot (msm_sync_init), legacy /dev/config0+frame0+control0.
Goal M1: DQBUF one real frame from /dev/video0. M2: v4l2src. M3: getUserMedia in Atlas.

## Reference: mainline PROVEN VFE31+CSIPHY sequence (1280x1024 UYVY PIX -> WM0/WM4 DMA)
Source of truth = /home/herrie/webos/touchpad-kernel/linux-6.18-tenderloin/drivers/media/platform/qcom/camss/
  camss-vfe-3-1.c, camss-csiphy-8x60.c  + reports/VFE31_QCAMERALIB_REVERSE_ENGINEERING.md
NOTE: register-value list below (from mapping agent) is a SCAFFOLD — several values were
reconstructed/hedged by the agent. VERIFY every hex against the actual source line before use.
