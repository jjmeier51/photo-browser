"""Bottom-centre progress pills and toasts — the iOS app's non-blocking "activity pill" idea:
a job shows as a capsule with a spinner/progress line and never blocks the window."""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import QHBoxLayout, QLabel, QProgressBar, QVBoxLayout, QWidget


class Pill(QWidget):
    def __init__(self, title: str, parent=None):
        super().__init__(parent)
        self.setObjectName("Pill")
        self.title = QLabel(title)
        self.status = QLabel(""); self.status.setObjectName("Caption")
        self.bar = QProgressBar(); self.bar.setRange(0, 0); self.bar.setFixedWidth(120); self.bar.setTextVisible(False)
        col = QVBoxLayout(); col.setSpacing(1); col.setContentsMargins(0, 0, 0, 0)
        col.addWidget(self.title); col.addWidget(self.status)
        lay = QHBoxLayout(self); lay.setContentsMargins(16, 8, 16, 8); lay.setSpacing(12)
        lay.addLayout(col); lay.addWidget(self.bar)

    def set_progress(self, done: int, total: int, message: str = ""):
        if total > 0:
            self.bar.setRange(0, total); self.bar.setValue(done)
        else:
            self.bar.setRange(0, 0)
        if message:
            self.status.setText(message)
        self.status.setVisible(bool(self.status.text()))


class PillHost(QWidget):
    """Overlay that stacks pills at the bottom centre of its parent. `toast()` shows a transient one."""

    def __init__(self, parent: QWidget):
        super().__init__(parent)
        self.setAttribute(Qt.WA_TransparentForMouseEvents)
        self.lay = QVBoxLayout(self)
        self.lay.setContentsMargins(0, 0, 0, 28); self.lay.setSpacing(8)
        self.lay.setAlignment(Qt.AlignHCenter | Qt.AlignBottom)
        self.pills: dict[str, Pill] = {}
        parent.installEventFilter(self)
        self._fit()

    def eventFilter(self, obj, ev):
        if obj is self.parent() and ev.type() in (ev.Type.Resize, ev.Type.Show):
            self._fit()
        return False

    def _fit(self):
        p = self.parentWidget()
        if p:
            self.setGeometry(p.rect())
            self.raise_()

    def begin(self, key: str, title: str) -> Pill:
        self.end(key)
        pill = Pill(title)
        self.pills[key] = pill
        self.lay.addWidget(pill, 0, Qt.AlignHCenter)
        self.raise_(); self.show()
        return pill

    def update(self, key: str, done: int, total: int, message: str = ""):
        if key in self.pills:
            self.pills[key].set_progress(done, total, message)

    def end(self, key: str):
        pill = self.pills.pop(key, None)
        if pill:
            self.lay.removeWidget(pill)
            pill.deleteLater()

    def toast(self, text: str, seconds: float = 3.5):
        key = f"toast-{id(text)}-{seconds}"
        pill = self.begin(key, text)
        pill.bar.hide(); pill.status.hide()
        QTimer.singleShot(int(seconds * 1000), lambda: self.end(key))
