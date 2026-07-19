# Canvas JPEG + WebP encoders for WPE WebKit 2.52.4

Enables `canvas.toDataURL('image/jpeg')` and `('image/webp')` (html5test 2D-Graphics JPEG + WebP rows,
which are *encoder* tests). Upstream WPE (Cairo, non-GTK) only encoded PNG; the GTK path uses gdk-pixbuf
which isn't in the WPE sysroot. `libjpeg.so.62` + `libwebp.so.7` are already linked (for the decoders) and
contain the encode symbols, so no CMake/link changes — pure code. Build tree is NOT git; re-apply after a
clean checkout. Confirmed on-device: PNG/JPEG/WebP toDataURL all green.

## 1. Source/WebCore/platform/graphics/cairo/ImageBufferUtilitiesCairo.cpp
In the `#if !PLATFORM(GTK)` block, after `writeFunction`, close+reopen the namespace to insert the C includes,
and replace the PNG-only `encodeImage`/`encodeData` with libjpeg + libwebp encoders:
- Add (at file scope, inside the `#if !PLATFORM(GTK)`): `#include <cstdio>/<cstdlib>/<csetjmp>`, `extern "C" { #include <jpeglib.h> }`, `#include <webp/encode.h>`.
- `cairoSurfaceToRGBA()` — un-premultiply ARGB32/RGB24 → tight RGBA (use `.mutableSpan().data()` / `.span().data()`; `Vector::data()` is PRIVATE in this WTF).
- `encodeJPEG()` — libjpeg mem-dest, RGB scanlines, setjmp error handler, quality from arg (default 92).
- `encodeWebP()` — `WebPEncodeRGBA` + `WebPFree`, quality default 80.
- `encodeImage(image, mimeType, quality, output)` dispatches png/jpeg|jpg/webp; `encodeData` passes `quality` through (upstream ignored it).

## 2. Source/WebCore/platform/MIMETypeRegistry.cpp  (~line 502, `#elif USE(CAIRO)` encode set)
```
#elif USE(CAIRO)
        "image/png"_s,
+       "image/jpeg"_s,
+       "image/jpg"_s,
+       "image/webp"_s,
```

GOTCHA: WTF `Vector::data()` is private — must use `.mutableSpan().data()` (mutable) / `.span().data()` (const).
