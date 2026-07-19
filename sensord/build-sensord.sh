#!/bin/bash
# Build atlas-sensord with the PalmPDK toolchain (arm-none-linux-gnueabi gcc 4.3.3) so it links the
# SYSTEM libhal.so / SYSTEM glibc — exactly what the stock device provides. Do NOT build it with the
# Atlas glibc-2.25 cross toolchain: libhal.so + its deps are system-glibc, and the point of this helper
# is to run OUTSIDE the Atlas private-glibc sandbox.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PDK=/opt/PalmPDK
CC=$PDK/arm-gcc/bin/arm-none-linux-gnueabi-gcc
HALINC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/staging/include

# libhal.so to link against (device copy pulled to the tree; runtime uses /usr/lib/libhal.so on-device)
[ -f "$HERE/libhal.so" ] || cp /tmp/libhal.so "$HERE/libhal.so" 2>/dev/null || { echo "need libhal.so (novacom get file:///usr/lib/libhal.so > $HERE/libhal.so)"; exit 1; }

"$CC" -O2 -Wall -std=gnu99 -march=armv7-a -mtune=cortex-a8 -mfloat-abi=softfp -mfpu=neon \
  -I"$HALINC" \
  "$HERE/atlas-sensord.c" -o "$HERE/atlas-sensord" \
  -L"$HERE" -lhal \
  -Wl,--allow-shlib-undefined \
  -Wl,--unresolved-symbols=ignore-in-shared-libs

echo "built: $HERE/atlas-sensord"
file "$HERE/atlas-sensord" 2>/dev/null | sed 's/^/  /'
"${PDK}/arm-gcc/bin/arm-none-linux-gnueabi-readelf" -d "$HERE/atlas-sensord" 2>/dev/null | grep -iE 'NEEDED|rpath' | sed 's/^/  /'
