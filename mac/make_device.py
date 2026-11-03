"""Fetches the stock Widevine L3 device and BuyDRM cert from PassesDL and stores them."""
import pathlib
import re
import urllib.request

from pywidevine import Device

SRC = ("https://raw.githubusercontent.com/Xewdy444/PassesDL"
       "/main/utils/passes/drm/constants.py")

raw = urllib.request.urlopen(SRC, timeout=30).read().decode("utf-8")


def grab(name: str) -> str:
    m = re.search(rf'{name}[^=]*=\s*\(\s*"([^"]+)"', raw, re.S)
    if not m:
        raise SystemExit(f"{name} not found in source")
    b64 = m.group(1).strip()
    return b64 + "=" * (-len(b64) % 4)          # restore padding


folder = pathlib.Path.home() / "Library/Application Support/SafeFinder"
folder.mkdir(parents=True, exist_ok=True)

device = folder / "device.wvd"
Device.loads(grab("DEFAULT_DEVICE")).dump(str(device))
print(device, device.stat().st_size, "bytes")

cert = folder / "service_cert.txt"
cert.write_text(grab("BUYDRM_SERVICE_CERTIFICATE"), encoding="utf-8")
print(cert, cert.stat().st_size, "bytes")