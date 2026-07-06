#!/bin/bash
# One-command autonomous redeploy + scroll test for the Atlas WPE BrowserServer.
#   Usage: ./redeploy-test.sh [stepPx] [intervalMs] [loadWaitSec]
#   Env:   SO=1  -> also deploy libWPEBackend-atlas.so   NODEPLOY=1 -> skip deploy (just relaunch+test)
#          URL=... (default en.wikipedia.org/wiki/WebOS)
# Flow: stop upstart atlas -> put binary -> start it -> relaunch app at URL -> trigger sweep -> report.
STEP=${1:-120}; MS=${2:-50}; LOADWAIT=${3:-22}
URL=${URL:-https://en.wikipedia.org/wiki/WebOS}
BIN=browserserver-wpe/obj/BrowserServer-atlas
if [ "$NODEPLOY" != "1" ]; then
  echo "=== stop atlas + deploy ==="
  cat <<'SH' | novacom run file://bin/sh
stop atlas 2>/dev/null
for p in $(ps -ef|grep BrowserServer-atlas|grep -v grep|awk '{print $2}'); do kill -9 $p 2>/dev/null; done
sleep 1; echo "stopped (BS left: $(ps -ef|grep BrowserServer-atlas|grep -v grep|wc -l))"
SH
  novacom put file:///media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/BrowserServer-atlas < "$BIN" && echo "deployed BIN $(stat -c%s $BIN)"
  if [ "$SO" = "1" ]; then
    novacom put file:///media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/lib/libWPEBackend-atlas.so < backend-atlas/libWPEBackend-atlas.so && echo "deployed SO"
  fi
fi
echo "=== start atlas, wait for socket, relaunch app at $URL ==="
cat <<SH | novacom run file://bin/sh
rm -f /tmp/atlas_scrolltest.result /tmp/bpwpe.log /tmp/bs.log /tmp/yapserver.atlas
start atlas 2>/dev/null
sleep 5   # the wrapper waits for LunaSysMgr then sleeps 3 before creating the socket
i=0; while [ \$i -lt 25 ] && [ ! -S /tmp/yapserver.atlas ]; do sleep 1; i=\$((i+1)); done
echo "BS socket up after \$((i+5))s (bs.log=\$(wc -c </tmp/bs.log 2>/dev/null))"
nohup luna-send -n 1 -f luna://com.palm.applicationManager/launch '{"id":"org.webosports.app.atlas","params":{"target":"$URL"}}' >/tmp/launch.out 2>&1 &
sleep 6; echo "launch: \$(cat /tmp/launch.out | tr -d '\n')"
SH
echo "waiting ${LOADWAIT}s for page load..."; sleep "$LOADWAIT"
echo "=== trigger sweep (step=${STEP} ms=${MS}) ==="
cat <<SH | novacom run file://bin/sh
echo "$STEP $MS" > /tmp/atlas_test.cfg
touch /tmp/atlas_scrolltest
SH
sleep 26
cat <<'SH' | novacom run file://bin/sh
echo "=== RESULT ==="
cat /tmp/atlas_scrolltest.result 2>/dev/null || echo "(no result — test did not run)"
echo "--- STRIP (last 5) ---"; grep -E 'STRIP ' /tmp/bs.log 2>/dev/null | tail -5
echo "--- PERF (last 2) ---"; grep -E 'PERF ' /tmp/bs.log 2>/dev/null | tail -2
echo "--- pageHeight seen ---"; grep -E 'onContentHeight|msgContentsSizeChanged|pageHeight|contentsSize' /tmp/bpwpe.log 2>/dev/null | tail -3
SH
