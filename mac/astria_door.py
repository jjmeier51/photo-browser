"""Astria through a browser window on this Mac — for when Cloudflare is checking the network's address.

**Why** (Nov 20, a real Check Connection): both ways the app reaches Astria directly — Python's networking and the
Mac's own curl — came back with Cloudflare's "Just a moment…" browser check. That's the address being checked, and
that check is one only a person in a browser can answer. So this is the third way (`astria.AutoTransport.browser`):
a small window holding a real browser on `api.astria.ai`. **The person answers the check there**, as they would in
Safari; from then on the app's Astria requests are made *by that browser* (`fetch` from its page — the browser's own
connection, cookies and User-Agent, plus the person's key as the Authorization header), until the clearance runs
out and the window asks again. Nothing here answers the check for the person or makes anything look like what it
isn't — it's the way the app's downloaders already handle a site's check (SimpCity's, the file hosts').

**How**: `Door` lives on the window's thread and takes one request at a time (`Door.ask`, a queued signal —
`BrowserTransport.send` is called from the jobs' threads and waits on an Event). For each: make sure the page is on
Astria's origin; ask a small question without the key (`PROBE`) — if the answer is the check, show the window and
ask again every 1.5 s until it isn't (or `CHECK_WAIT` passes / the person presses Not Now or closes the window:
the check's own answer is handed back, so the message says what happened, and the window doesn't offer itself again
for `DECLINED_FOR` unless asked — Check Connection `insist`s); then send. The body goes over in pieces (a photo is megabytes:
base64 in ~512 KB scripts), the answer comes back as status + headers + base64. Scripts run in Qt's
*application world*, so the key is never a variable the page's own scripts can read.

Only `astria.BASE` addresses go this way (same origin); result pictures are fetched as before. A request that
fails after it was sent is `Ambiguous`, as on the other ways (the caller looks before sending again).
"""
from __future__ import annotations

import base64
import json
import threading
import time
import uuid
from urllib.parse import urlsplit

from PySide6.QtCore import QObject, QThread, QTimer, QUrl, Qt, Signal
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QVBoxLayout, QWidget

import astria as A

CHECK_WAIT = 180.0            # seconds the window waits for the person to answer the check
DECLINED_FOR = 120.0          # after "Not Now" (or no answer): this long before the window offers itself again
PAGE = "/tunes?limit=1"       # the address the window's page sits on: Astria's own short answer, never a redirect
MAX_LOADS = 4                 # loads of that page for one request before this way is given up for it
CHUNK = 384_000               # bytes of body per script (a multiple of 3: each piece is its own base64)
POLL_MS = 120                 # how often a sent request's answer is looked for
PROBE_EVERY_MS = 1500

PROBE = r"""(function(){ window.__pb = window.__pb || {}; var id = __ID__; window.__pb[id] = null;
  fetch(__URL__, {headers: {'Accept': 'application/json'}, credentials: 'include', cache: 'no-store'})
    .then(function(r){ return r.text().then(function(t){
      window.__pb[id] = JSON.stringify({status: r.status, mitigated: r.headers.get('cf-mitigated') || '',
                                        ray: r.headers.get('cf-ray') || '', head: t.slice(0, 600)}); }); })
    .catch(function(e){ window.__pb[id] = JSON.stringify({status: 0, error: String(e)}); });
  return true; })()"""

BEGIN = r"""(function(){ window.__pbBody = window.__pbBody || {}; window.__pbBody[__ID__] = []; return true; })()"""
PIECE = r"""(function(){ window.__pbBody[__ID__].push(__B64__); return true; })()"""
SEND = r"""(function(){ window.__pb = window.__pb || {}; var id = __ID__; window.__pb[id] = null;
  var parts = (window.__pbBody || {})[id], body;
  if (parts) {
    body = new Blob(parts.map(function(s){ var bin = atob(s), a = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i); return a; }));
    delete window.__pbBody[id];
  }
  fetch(__URL__, {method: __METHOD__, headers: __HEADERS__, body: body, credentials: 'include', cache: 'no-store',
                  redirect: 'manual'})
    .then(function(r){ return r.arrayBuffer().then(function(buf){
      var u = new Uint8Array(buf), s = '';
      for (var i = 0; i < u.length; i += 32768) s += String.fromCharCode.apply(null, u.subarray(i, i + 32768));
      var h = {}; r.headers.forEach(function(v, k){ h[k] = v; });
      window.__pb[id] = JSON.stringify({status: r.status, headers: h, body: btoa(s)}); }); })
    .catch(function(e){ window.__pb[id] = JSON.stringify({status: 0, error: String(e)}); });
  return true; })()"""
TAKE = r"""(function(){ var v = (window.__pb || {})[__ID__]; if (v) delete window.__pb[__ID__]; return v || ''; })()"""

CHECKED = (403, b"<html><title>Just a moment...</title></html>", {"cf-mitigated": "challenge"})


class _Call:
    def __init__(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> None:
        self.id = uuid.uuid4().hex
        self.method, self.url, self.headers, self.body, self.timeout = method, url, headers, body, timeout
        self.event = threading.Event()
        self.response: A.Response | None = None
        self.error: Exception | None = None
        self.sent = False                                    # the fetch was started (a failure after is ambiguous)

    def done(self, response: A.Response | None = None, error: Exception | None = None) -> None:
        self.response, self.error = response, error
        self.event.set()


class Door(QObject):
    """The window and its one browser page (module notes). Made on the window's thread; requests arrive by `ask`."""

    ask = Signal(object)

    def __init__(self) -> None:
        super().__init__()
        self.window: QWidget | None = None
        self.view = None
        self.queue: list[_Call] = []
        self.busy: _Call | None = None
        self.ray = ""
        self.declined_until = 0.0                            # "Not Now": no window before then (unless insisted)
        self.ask.connect(self._take, Qt.ConnectionType.QueuedConnection)

    # -- the window
    def _build(self) -> None:
        from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile
        from PySide6.QtWebEngineWidgets import QWebEngineView
        profile = QWebEngineProfile("astria", QApplication.instance())       # kept: the clearance lasts between launches
        profile.setPersistentCookiesPolicy(QWebEngineProfile.PersistentCookiesPolicy.ForcePersistentCookies)
        self.window = QWidget()
        self.window.setWindowTitle("Astria — Cloudflare's check")
        self.window.resize(560, 640)
        v = QVBoxLayout(self.window)
        self.note = QLabel("")
        self.note.setWordWrap(True)
        v.addWidget(self.note)
        self.view = QWebEngineView()
        self.view.setPage(QWebEnginePage(profile, self.view))
        v.addWidget(self.view, 1)
        self.cancel = QPushButton("Not Now")
        self.cancel.clicked.connect(self._give_up)
        v.addWidget(self.cancel, 0, Qt.AlignmentFlag.AlignRight)
        self.window.closeEvent = self._closed                # type: ignore[method-assign]

    def _closed(self, event) -> None:
        event.accept()
        self._give_up()

    def _say(self, text: str) -> None:
        if self.window is not None:
            self.note.setText(text)

    def _js(self, source: str, done) -> None:
        from PySide6.QtWebEngineCore import QWebEngineScript
        self.view.page().runJavaScript(source, QWebEngineScript.ScriptWorldId.ApplicationWorld, done)

    @staticmethod
    def _fill(template: str, **values) -> str:
        out = template
        for k, v in values.items():
            out = out.replace(f"__{k}__", json.dumps(v))
        return out

    def _on_origin(self) -> bool:
        want = urlsplit(A.BASE)
        url = self.view.page().url()
        return url.host() == (want.hostname or "") and url.scheme() == want.scheme

    # -- one request at a time
    def _take(self, call: _Call) -> None:
        self.queue.append(call)
        self._next()

    def _next(self) -> None:
        if self.busy is not None or not self.queue:
            return
        call = self.busy = self.queue.pop(0)
        try:
            if self.view is None:
                self._build()
        except Exception as e:  # noqa: BLE001 — no web engine here: this way simply isn't there
            self._finish(call, error=A.Transport.PreSend(f"no browser window ({e})"))
            return
        call.began = time.monotonic()                        # type: ignore[attr-defined]
        call.shown = False                                   # type: ignore[attr-defined]
        call.loads = 0                                       # type: ignore[attr-defined]
        if self._on_origin():
            self._probe(call)
        else:
            self._load(call)

    def _load(self, call: _Call) -> None:
        page = self.view.page()
        call.loads += 1                                      # type: ignore[attr-defined]
        if call.loads > MAX_LOADS:                           # type: ignore[attr-defined]
            self._finish(call, error=A.Transport.PreSend("the browser window couldn't stay on Astria's address"))
            return

        def loaded(_ok: bool) -> None:
            try:
                page.loadFinished.disconnect(loaded)
            except (RuntimeError, TypeError):
                pass
            QTimer.singleShot(300, lambda: self._probe(call))
        page.loadFinished.connect(loaded)
        page.load(QUrl(A.BASE + PAGE))

    def _probe(self, call: _Call) -> None:
        """Is the front door letting this browser through? (A small question, without the key.)"""
        if self.busy is not call:
            return
        if not self._on_origin():                            # the check's page went somewhere else: back to Astria
            self._load(call)
            return
        pid = uuid.uuid4().hex
        self._js(self._fill(PROBE, ID=pid, URL=A.BASE + "/tunes?limit=1"), lambda _r: self._probe_poll(call, pid, 0))

    def _probe_poll(self, call: _Call, pid: str, tries: int) -> None:
        if self.busy is not call:
            return

        def got(raw) -> None:
            if self.busy is not call:
                return
            if not raw:
                if tries > 250:                              # ~30 s without an answer: the page is stuck — again
                    self._after_probe(call, None)
                else:
                    QTimer.singleShot(POLL_MS, lambda: self._probe_poll(call, pid, tries + 1))
                return
            try:
                self._after_probe(call, json.loads(raw))
            except ValueError:
                self._after_probe(call, None)
        self._js(self._fill(TAKE, ID=pid), got)

    def _after_probe(self, call: _Call, answer: dict | None) -> None:
        status = int((answer or {}).get("status") or 0)
        through = False
        if status:
            self.ray = str(answer.get("ray") or "")
            r = A.Response(status, str(answer.get("head") or "").encode("utf-8", "replace"),
                           {"cf-mitigated": str(answer.get("mitigated") or ""), "cf-ray": self.ray})
            through = 200 <= status < 300 or A.explain(r).kind != "challenge"
        if through:
            if getattr(call, "shown", False) and self.window is not None:
                self.window.hide()                           # answered: the window steps aside, the page stays
            self._send(call)
            return
        waited = time.monotonic() - call.began               # type: ignore[attr-defined]
        if waited > CHECK_WAIT:
            self.declined_until = time.monotonic() + DECLINED_FOR
            if self.window is not None:
                self.window.hide()
            self._finish(call, response=self._checked())
            return
        if not call.shown:                                   # type: ignore[attr-defined]
            if time.monotonic() < self.declined_until:       # the person said Not Now a moment ago: not again yet
                self._finish(call, response=self._checked())
                return
            call.shown = True                                # type: ignore[attr-defined]
            self._say("Astria's front door (Cloudflare) wants to check that a person is here. Answer the check "
                      "below — this window closes by itself once it's passed, and what you asked for carries on.")
            self.window.show()
            self.window.raise_()
            self.window.activateWindow()
            if self._on_origin():
                self.view.page().load(QUrl(A.BASE + PAGE))   # the page itself is where the check appears
        QTimer.singleShot(PROBE_EVERY_MS, lambda: self._probe(call))

    def _checked(self) -> A.Response:
        status, body, headers = CHECKED
        return A.Response(status, body, {**headers, "cf-ray": self.ray}, "browser")

    def _give_up(self) -> None:
        """Not Now / the window closed: whoever is waiting on the check gets the check's own answer."""
        call = self.busy
        if call is not None and getattr(call, "shown", False) and not call.sent:
            self.declined_until = time.monotonic() + DECLINED_FOR
            self._finish(call, response=self._checked())
        if self.window is not None:
            self.window.hide()

    # -- sending
    def _send(self, call: _Call) -> None:
        heads = {k: v for k, v in call.headers.items() if k.lower() != "user-agent"}    # the browser's own stands
        body = call.body
        pieces = [body[i:i + CHUNK] for i in range(0, len(body), CHUNK)] if body else []

        def go(_r=None) -> None:
            if self.busy is not call:
                return
            call.sent = True
            call.sent_at = time.monotonic()                  # type: ignore[attr-defined]
            self._js(self._fill(SEND, ID=call.id, URL=call.url, METHOD=call.method, HEADERS=heads),
                     lambda _r2: self._send_poll(call))

        def piece(i: int) -> None:
            if self.busy is not call:
                return
            if i >= len(pieces):
                go()
                return
            self._js(self._fill(PIECE, ID=call.id, B64=base64.b64encode(pieces[i]).decode("ascii")),
                     lambda _r: piece(i + 1))
        if pieces:
            self._js(self._fill(BEGIN, ID=call.id), lambda _r: piece(0))
        else:
            go()

    def _send_poll(self, call: _Call) -> None:
        if self.busy is not call:
            return

        def got(raw) -> None:
            if self.busy is not call:
                return
            if not raw:
                if time.monotonic() - call.sent_at > call.timeout + 15:      # type: ignore[attr-defined]
                    self._finish(call, error=A.Transport.Ambiguous("the browser window got no answer in time"))
                else:
                    QTimer.singleShot(POLL_MS, lambda: self._send_poll(call))
                return
            try:
                answer = json.loads(raw)
                status = int(answer.get("status") or 0)
                if not status:
                    raise A.Transport.Ambiguous(str(answer.get("error") or "the browser's request failed"))
                r = A.Response(status, base64.b64decode(answer.get("body") or ""), dict(answer.get("headers") or {}),
                               "browser")
            except A.Transport.Ambiguous as e:
                self._finish(call, error=e)
                return
            except (ValueError, TypeError) as e:
                self._finish(call, error=A.Transport.Ambiguous(f"the browser's answer couldn't be read ({e})"))
                return
            self._finish(call, response=r)
        self._js(self._fill(TAKE, ID=call.id), got)

    def _finish(self, call: _Call, response: A.Response | None = None, error: Exception | None = None) -> None:
        if self.busy is call:
            self.busy = None
        call.done(response, error)
        QTimer.singleShot(0, self._next)


class BrowserTransport(A.Transport):
    """`astria.Transport` over the `Door` — callable from the jobs' threads; never from the window's own (it would
    wait on itself: said as "this way isn't there", and the caller goes on without it)."""

    def insist(self) -> None:
        """The person asked for the check themselves (Check Connection): an earlier "Not Now" no longer holds."""
        if _DOOR is not None:
            _DOOR.declined_until = 0.0

    def send(self, method: str, url: str, headers: dict, body: bytes | None, timeout: float) -> A.Response:
        door = _DOOR
        app = QApplication.instance()
        if door is None or app is None:
            raise A.Transport.PreSend("no browser window in this run")
        if QThread.currentThread() is app.thread():
            raise A.Transport.PreSend("asked from the window's own thread")
        if not url.startswith(A.BASE):
            raise A.Transport.PreSend("not Astria's address")
        call = _Call(method, url, headers, body, timeout)
        door.ask.emit(call)
        if not call.event.wait(timeout + CHECK_WAIT + 60):
            raise A.Transport.Ambiguous("the browser window didn't answer")
        if call.error is not None:
            raise call.error
        assert call.response is not None
        return call.response


_DOOR: Door | None = None
_ROUTE = BrowserTransport()


def ensure() -> bool:
    """Makes the door (on the window's thread — call it from there) and hands its way to astria. → whether it's there."""
    global _DOOR
    app = QApplication.instance()
    if app is None or QThread.currentThread() is not app.thread():
        return _DOOR is not None
    if _DOOR is None:
        _DOOR = Door()
        A.set_browser_route(_ROUTE)
    return True
