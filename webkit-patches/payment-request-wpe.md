# Payment Request on WPE WebKit 2.52.4 — 3 source patches

These enable `window.PaymentRequest` (html5test Payments 0/5 → 5/5) on WPE, which upstream keeps disabled
because it ties PaymentRequest to Apple Pay. The WebKit build tree (`build/wpewebkit-2.52.4`) is NOT git, so
these are lost on a clean checkout — re-apply them. No Apple Pay / payment backend needed: the cross-platform
PaymentRequest works standalone (`show()` rejects `NotSupportedError` cleanly).

Build: `-DENABLE_PAYMENT_REQUEST=ON` at cmake configure, then the 3 edits below, then rebuild libWPEWebKit.

## 1. Source/WebKit/WebProcess/WebPage/WebPage.cpp  (~line 4847) — THE KEY GATE
Upstream force-sets the setting from Apple Pay's pref (false on WPE), overriding everything else.
```
#if ENABLE(PAYMENT_REQUEST)
-    settings.setPaymentRequestEnabled(store.getBoolValueForKey(WebPreferencesKey::applePayEnabledKey()));
+    settings.setPaymentRequestEnabled(true);
#endif
```

## 2. Source/WebCore/page/Settings.yaml  (~line 322) — the WebCore default (belt-and-suspenders)
```
PaymentRequestEnabled:
  ...
  defaultValue:
    WebCore:
-      default: false
+      default: true
```

## 3. Source/WebCore/Modules/paymentrequest/PaymentRequest.cpp  (lines 241, 278) — gcc 12.5 build fix
`optional<Vector<>> = { { } }` is an ambiguous overload for gcc 12.5; make the type explicit.
```
-            details.shippingOptions = { { } };
+            details.shippingOptions = Vector<PaymentShippingOption> { };
...
-        details.modifiers = { { } };
+        details.modifiers = Vector<PaymentDetailsModifier> { };
```

Verify on-device: `typeof window.PaymentRequest` === "function" on any https page (needs SecureContext).
