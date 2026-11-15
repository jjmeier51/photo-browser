"""Background jobs (metadata reads, bulk writes, renames) on Qt's thread pool, reporting back
through signals so the UI never blocks on a slow external drive — the same rule the iOS app lives
by (nothing heavy on the main thread)."""

from __future__ import annotations

import traceback
from typing import Callable

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal, Qt


class JobSignals(QObject):
    progress = Signal(int, int, str)      # done, total, message
    finished = Signal(object)             # result
    failed = Signal(str)


class Job(QRunnable):
    """Runs `fn(progress)` off the main thread. `progress(done, total, message)` is safe to call
    from inside `fn`."""

    def __init__(self, fn: Callable[[Callable[[int, int, str], None]], object]):
        super().__init__()
        self.fn = fn
        self.signals = JobSignals()
        self.setAutoDelete(True)

    def run(self):
        try:
            result = self.fn(lambda d, t, m="": self.signals.progress.emit(d, t, m))
        except Exception:
            self.signals.failed.emit(traceback.format_exc())
            return
        self.signals.finished.emit(result)


_pool = QThreadPool()
_pool.setMaxThreadCount(3)
_keeper = QObject()            # main-thread parent that keeps each job's signals object alive
_active: set[Job] = set()      # jobs in flight (a QRunnable auto-deletes; the Python side must not)


def run_job(fn, on_finished=None, on_failed=None, on_progress=None) -> Job:
    """Start `fn` on the pool. The callbacks are plain Python callables, so the connections MUST be
    queued explicitly: with an auto connection PySide would invoke them straight from the worker
    thread (there's no receiver QObject to infer a thread from), and they touch widgets. The
    `JobSignals` object is parented to a main-thread QObject so it outlives the runnable (which is
    auto-deleted the moment `run` returns) until the queued delivery has happened."""
    job = Job(fn)
    sig = job.signals
    sig.setParent(_keeper)
    _active.add(job)

    def _done(*_):
        _active.discard(job)
        sig.deleteLater()

    if on_finished:
        sig.finished.connect(on_finished, Qt.QueuedConnection)
    if on_failed:
        sig.failed.connect(on_failed, Qt.QueuedConnection)
    if on_progress:
        sig.progress.connect(on_progress, Qt.QueuedConnection)
    sig.finished.connect(_done, Qt.QueuedConnection)
    sig.failed.connect(_done, Qt.QueuedConnection)
    _pool.start(job)
    return job
