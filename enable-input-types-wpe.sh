#!/bin/bash
# html5test Forms: enable date/time/color input types for WPE. These are runtime prefs
# (InputType{Color,Date,DateTimeLocal,Month,Time,Week}Enabled), status mature/embedder, default TRUE for
# GTK/Cocoa but FALSE for WPE. Flip the WebKit-block default false->true in UnifiedWebPreferences.yaml so a
# WebKit rebuild bakes them on (DEFAULT_VALUE_FOR_InputTypeDateEnabled std::true_type{}). Idempotent.
# (BrowserServer also toggles them at runtime via the WebKitFeature list as a backup — atlas-wpe-backend.)
set -u
Y="${1:-/home/herrie/webos/wpe/build/wpewebkit-2.52.4/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml}"
python3 - "$Y" <<'PY'
import sys
Y=sys.argv[1]; lines=open(Y).read().split("\n")
prefs=["InputTypeColorEnabled","InputTypeDateEnabled","InputTypeDateTimeLocalEnabled",
       "InputTypeMonthEnabled","InputTypeTimeEnabled","InputTypeWeekEnabled"]
def fix(pref):
    for i,l in enumerate(lines):
        if l==pref+":": start=i; break
    else: return "not found"
    end=len(lines)
    for j in range(start+1,len(lines)):
        if lines[j] and not lines[j][0].isspace(): end=j; break
    for j in range(start,end):
        if lines[j].strip()=="WebKit:":
            for k in range(j+1,end):
                s=lines[k].strip()
                if s.startswith("default:"):
                    if "false" in lines[k]: lines[k]=lines[k].replace("false","true"); return "false->true"
                    return "already true"
                if s.endswith(":") and not s.startswith('"'): break
    return "WebKit default not found"
for p in prefs: print(f"  {p}: {fix(p)}")
open(Y,"w").write("\n".join(lines))
PY
echo "done — rebuild WebKit to bake in (ninja -j24 in _b)."
