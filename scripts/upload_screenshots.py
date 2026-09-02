#!/usr/bin/env python3
"""Загрузка скриншотов витрины в App Store Connect."""
import sys, os, hashlib, json, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import call, token

def upload(loc_id, files, display_type="APP_DESKTOP"):
    st, d = call("GET", f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")
    sets = [s for s in d.get('data', []) if s['attributes']['screenshotDisplayType'] == display_type]
    if sets:
        set_id = sets[0]['id']
        print("набор уже есть:", set_id)
    else:
        st, d = call("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
        if st >= 300:
            print("не смог создать набор:", [e.get('detail') for e in d.get('errors', [])]); return
        set_id = d['data']['id']
        print("создан набор:", set_id)

    for path in files:
        name = os.path.basename(path)
        size = os.path.getsize(path)
        st, d = call("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": name, "fileSize": size},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})
        if st >= 300:
            print(" ", name, "ошибка:", [e.get('detail') for e in d.get('errors', [])]); continue
        sid = d['data']['id']
        ops = d['data']['attributes']['uploadOperations']
        blob = open(path, 'rb').read()
        for op in ops:
            chunk = blob[op['offset']:op['offset'] + op['length']]
            req = urllib.request.Request(op['url'], data=chunk, method=op['method'])
            for h in op.get('requestHeaders', []):
                req.add_header(h['name'], h['value'])
            urllib.request.urlopen(req).read()
        md5 = hashlib.md5(blob).hexdigest()
        st, d = call("PATCH", f"/v1/appScreenshots/{sid}", {"data": {
            "type": "appScreenshots", "id": sid,
            "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
        print(" ", name, "→", "загружен" if st < 300 else [e.get('detail') for e in d.get('errors', [])])

if __name__ == "__main__":
    upload(sys.argv[1], sys.argv[2:])
