"""The programs Photo Browser for Mac has started and must not leave running — ffmpeg encoding a video, mflux
drawing a picture, a Swift helper.

A worker thread that runs one of these is a daemon thread: when the app quits, the thread simply stops, and
the program it started carries on by itself — an ffmpeg writing a hidden half-made video for another twenty
minutes, an mflux holding 10 GB of memory. So whoever starts a long-running program hands it here:

    proc = subprocess.Popen(cmd, …, **children.OWN_GROUP)
    with children.tracked(proc):
        …read its output, wait for it…

`tracked` remembers it while it runs; at exit (and from `stop_all`, which the main window calls on quit) every
one still running is asked to stop, then made to. `OWN_GROUP` starts it in its own process group, so its own
children go with it. `wait_or_stop` waits for a program while watching a stop flag — a program that prints
nothing (a model loading, a download) is otherwise only noticed at its next line of output.

No Qt here; quick programs run with `subprocess.run` needn't bother.
"""
from __future__ import annotations

import atexit
import os
import signal
import subprocess
import threading
from contextlib import contextmanager
from typing import Callable

OWN_GROUP = {"start_new_session": True} if os.name == "posix" else {}

_lock = threading.Lock()
_running: set[subprocess.Popen] = set()


def track(proc: subprocess.Popen) -> subprocess.Popen:
    with _lock:
        _running.add(proc)
    return proc


def forget(proc: subprocess.Popen) -> None:
    with _lock:
        _running.discard(proc)


@contextmanager
def tracked(proc: subprocess.Popen):
    """Remembered for as long as the `with` lasts; if it's left with the program still running (an exception,
    a Stop), the program is stopped."""
    track(proc)
    try:
        yield proc
    finally:
        if proc.poll() is None:
            stop(proc)
        forget(proc)


def _signal(proc: subprocess.Popen, sig: int) -> None:
    try:
        if os.name == "posix" and OWN_GROUP:
            try:
                group = os.getpgid(proc.pid)
            except OSError:
                group = None
            if group is not None and group != os.getpgid(0):       # its own group (never ours): everything in it
                os.killpg(group, sig)
                return
        proc.send_signal(sig)
    except (OSError, ValueError):
        pass


def stop(proc: subprocess.Popen, grace: float = 3.0) -> None:
    """Asks the program to stop; makes it, if it hasn't within `grace` seconds."""
    if proc.poll() is not None:
        return
    _signal(proc, signal.SIGTERM)
    try:
        proc.wait(grace)
    except subprocess.TimeoutExpired:
        _signal(proc, signal.SIGKILL if hasattr(signal, "SIGKILL") else signal.SIGTERM)
        try:
            proc.wait(2.0)
        except subprocess.TimeoutExpired:
            pass


def wait_or_stop(proc: subprocess.Popen, stopped: Callable[[], bool], every: float = 0.25) -> bool:
    """Waits for the program to end. Returns False — having stopped it — as soon as `stopped()` says so."""
    while True:
        try:
            proc.wait(every)
            return True
        except subprocess.TimeoutExpired:
            if stopped():
                stop(proc)
                return False


def running() -> int:
    with _lock:
        return sum(1 for p in _running if p.poll() is None)


def stop_all(grace: float = 2.0) -> int:
    """Every program still running, stopped. Returns how many there were."""
    with _lock:
        live = [p for p in _running if p.poll() is None]
    for p in live:
        _signal(p, signal.SIGTERM)
    for p in live:
        try:
            p.wait(grace)
        except subprocess.TimeoutExpired:
            _signal(p, signal.SIGKILL if hasattr(signal, "SIGKILL") else signal.SIGTERM)
    with _lock:
        _running.difference_update(live)
    return len(live)


atexit.register(stop_all)
