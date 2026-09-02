#!/usr/bin/env python3
"""Заливка описаний витрины App Store из json-файлов."""
import sys, os, json, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import call

APP  = "6807722903"
VER  = "1e0f9609-901f-4ec2-92f6-870b5d28926c"
INFO = "7698eb9e-6d1e-4376-bc8e-09da960ece69"
SUPPORT = "https://github.com/iGrKukan/mantel"
PRIVACY = "https://igrkukan.github.io/mantel/privacy.html"

data = {}
for f in sorted(glob.glob(os.path.expanduser("~/Projects/Mantel/docs/store-locales-*.json"))):
    data.update(json.load(open(f)))
print("локалей к заливке:", len(data))

st, d = call("GET", f"/v1/appStoreVersions/{VER}/appStoreVersionLocalizations?limit=200")
have_ver = {l['attributes']['locale']: l['id'] for l in d.get('data', [])}
st, d = call("GET", f"/v1/appInfos/{INFO}/appInfoLocalizations?limit=200")
have_info = {l['attributes']['locale']: l['id'] for l in d.get('data', [])}

ok = fail = 0
for locale, v in sorted(data.items()):
    attrs = {"description": v["description"], "keywords": v["keywords"],
             "supportUrl": SUPPORT, "marketingUrl": SUPPORT}
    if locale in have_ver:
        st, r = call("PATCH", f"/v1/appStoreVersionLocalizations/{have_ver[locale]}",
                     {"data": {"type": "appStoreVersionLocalizations", "id": have_ver[locale], "attributes": attrs}})
    else:
        attrs["locale"] = locale
        st, r = call("POST", "/v1/appStoreVersionLocalizations", {"data": {
            "type": "appStoreVersionLocalizations", "attributes": attrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": VER}}}}})
    if st >= 300:
        print(f"  {locale}: описание — {[e.get('detail','')[:70] for e in r.get('errors',[])][:1]}"); fail += 1; continue

    iattrs = {"name": "Mantel+", "subtitle": v["subtitle"], "privacyPolicyUrl": PRIVACY}
    if locale in have_info:
        st, r = call("PATCH", f"/v1/appInfoLocalizations/{have_info[locale]}",
                     {"data": {"type": "appInfoLocalizations", "id": have_info[locale], "attributes": iattrs}})
    else:
        iattrs["locale"] = locale
        st, r = call("POST", "/v1/appInfoLocalizations", {"data": {
            "type": "appInfoLocalizations", "attributes": iattrs,
            "relationships": {"appInfo": {"data": {"type": "appInfos", "id": INFO}}}}})
    if st >= 300:
        print(f"  {locale}: подзаголовок — {[e.get('detail','')[:70] for e in r.get('errors',[])][:1]}"); fail += 1
    else:
        print(f"  {locale}: ok"); ok += 1

print(f"\nготово: {ok} локалей, ошибок: {fail}")
