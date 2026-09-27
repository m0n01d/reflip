#!/usr/bin/env python3
"""Renders the text/html part of a haul digest .eml to a plain HTML file,
with every "cid:<id>" image reference swapped for a data: URL built from
the matching inline part (matched by its Content-ID header). Lets you open
a HaulEmail.send output in a browser instead of a mail client.

Python 3 stdlib only.

Usage:
    python3 scripts/eml-preview.py in.eml out.html
"""
import base64
import sys
from email import message_from_binary_file


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: eml-preview.py in.eml out.html", file=sys.stderr)
        raise SystemExit(1)
    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, "rb") as f:
        msg = message_from_binary_file(f)

    html = None
    data_urls = {}
    for part in msg.walk():
        if part.is_multipart():
            continue
        content_type = part.get_content_type()
        if content_type == "text/html" and html is None:
            payload = part.get_payload(decode=True)
            charset = part.get_content_charset() or "utf-8"
            html = payload.decode(charset)
        elif content_type.startswith("image/"):
            cid = (part.get("Content-ID") or "").strip("<>")
            if cid:
                payload = part.get_payload(decode=True)
                b64 = base64.b64encode(payload).decode("ascii")
                data_urls[cid] = "data:" + content_type + ";base64," + b64

    if html is None:
        print("no text/html part found in " + in_path, file=sys.stderr)
        raise SystemExit(1)

    for cid, data_url in data_urls.items():
        html = html.replace("cid:" + cid, data_url)

    # Digest.htmlBody's fragment has no <head>, so a browser has nothing to
    # tell it the bytes are UTF-8 (the en dash and "·" turn to mojibake
    # without this) — wrap it in a minimal shell that declares it.
    page = '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>' + html + "</body></html>"

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(page)

    print("wrote " + out_path + " (" + str(len(data_urls)) + " inline image(s) inlined)")


if __name__ == "__main__":
    main()
