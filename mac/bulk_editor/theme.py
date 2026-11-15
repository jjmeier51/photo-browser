"""Look & feel — the iOS app's dark palette: a deep navy-to-black gradient behind translucent
panels, white text, iOS-blue accent, square tiles with rounded corners.

Everything visual is a Qt stylesheet so the widgets stay plain Qt (no custom painting except the
grid tiles). Colors live in `Palette` so a tweak here restyles the whole app.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Palette:
    navy_top = "#0D1733"       # Color(red: 0.05, green: 0.09, blue: 0.20) from the iOS gradient
    black = "#000000"
    panel = "rgba(255, 255, 255, 0.06)"
    panel_strong = "rgba(255, 255, 255, 0.10)"
    border = "rgba(255, 255, 255, 0.10)"
    text = "#F2F2F7"
    secondary = "#8E8E93"
    tertiary = "#636366"
    accent = "#0A84FF"
    accent_soft = "rgba(10, 132, 255, 0.28)"
    green = "#30D158"
    red = "#FF453A"
    yellow = "#FFD60A"
    tile = "#1C1C1E"


P = Palette()

STYLESHEET = f"""
* {{
    font-family: -apple-system, "SF Pro Text", "Helvetica Neue", "Segoe UI", sans-serif;
    font-size: 13px;
    color: {P.text};
}}
QMainWindow, QDialog {{
    background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 {P.navy_top}, stop:1 {P.black});
}}
QWidget#Sidebar, QWidget#Inspector {{
    background: {P.panel};
    border: 1px solid {P.border};
    border-radius: 12px;
}}
QWidget#Toolbar {{
    background: {P.panel};
    border: 1px solid {P.border};
    border-radius: 10px;
}}
QLabel#Title {{ font-size: 17px; font-weight: 600; }}
QLabel#Heading {{ font-size: 12px; font-weight: 600; color: {P.secondary}; letter-spacing: 0.5px; }}
QLabel#Secondary {{ color: {P.secondary}; }}
QLabel#Tertiary {{ color: {P.tertiary}; font-size: 12px; }}
QLabel#Caption {{ color: {P.secondary}; font-size: 12px; }}

QScrollArea, QScrollArea > QWidget > QWidget, QAbstractScrollArea {{ background: transparent; }}
QScrollArea {{ border: none; }}

QLineEdit, QTextEdit, QPlainTextEdit, QSpinBox, QDoubleSpinBox, QDateTimeEdit, QComboBox {{
    background: {P.panel_strong};
    border: 1px solid {P.border};
    border-radius: 8px;
    padding: 6px 8px;
    min-height: 18px;
    selection-background-color: {P.accent};
}}
QTextEdit, QPlainTextEdit {{ min-height: 40px; }}
QLineEdit:focus, QTextEdit:focus, QPlainTextEdit:focus, QSpinBox:focus, QDoubleSpinBox:focus,
QDateTimeEdit:focus, QComboBox:focus {{
    border: 1px solid {P.accent};
}}
QLineEdit[readOnly="true"] {{ color: {P.secondary}; }}
QComboBox::drop-down {{ border: none; width: 22px; }}
QComboBox QAbstractItemView {{
    background: #1C1C1E; border: 1px solid {P.border}; selection-background-color: {P.accent};
    outline: none;
}}
QSpinBox::up-button, QSpinBox::down-button, QDoubleSpinBox::up-button, QDoubleSpinBox::down-button,
QDateTimeEdit::up-button, QDateTimeEdit::down-button {{ width: 14px; border: none; }}

QPushButton {{
    background: {P.panel_strong};
    border: 1px solid {P.border};
    border-radius: 8px;
    padding: 6px 14px;
}}
QPushButton:hover {{ background: rgba(255,255,255,0.16); }}
QPushButton:pressed {{ background: rgba(255,255,255,0.22); }}
QPushButton:disabled {{ color: {P.tertiary}; }}
QPushButton#Primary {{
    background: {P.accent}; border: 1px solid {P.accent}; color: white; font-weight: 600;
}}
QPushButton#Primary:hover {{ background: #2A94FF; }}
QPushButton#Primary:disabled {{ background: rgba(10,132,255,0.35); border-color: transparent; color: rgba(255,255,255,0.6); }}
QPushButton#Destructive {{ color: {P.red}; }}
QPushButton#Flat {{ background: transparent; border: none; padding: 4px 8px; color: {P.accent}; }}
QPushButton#Flat:hover {{ background: {P.panel}; }}
QToolButton {{
    background: transparent; border: none; border-radius: 6px; padding: 4px;
}}
QToolButton:hover {{ background: {P.panel_strong}; }}
QToolButton:checked {{ background: {P.accent_soft}; }}

QTreeView, QListView, QTableView, QTableWidget {{
    background: transparent;
    border: none;
    outline: none;
    selection-background-color: {P.accent_soft};
}}
QTreeView::item {{ padding: 4px 2px; border-radius: 6px; }}
QTreeView::item:selected, QTableView::item:selected {{ background: {P.accent_soft}; color: {P.text}; }}
QTreeView::item:hover {{ background: {P.panel}; }}
QTreeView::branch {{ background: transparent; }}
QHeaderView {{ background: transparent; border: none; }}
QHeaderView::section {{
    background: transparent; color: {P.secondary}; border: none;
    border-bottom: 1px solid {P.border}; padding: 6px; font-weight: 600;
}}
QTableView {{ gridline-color: {P.border}; alternate-background-color: rgba(255,255,255,0.03); }}
QTableView::item {{ padding: 4px 6px; }}
QTableCornerButton::section {{ background: transparent; border: none; }}
QGroupBox {{
    border: 1px solid {P.border}; border-radius: 10px; margin-top: 12px; padding: 10px 8px 6px 8px;
}}
QGroupBox::title {{ subcontrol-origin: margin; left: 10px; padding: 0 4px; color: {P.secondary}; }}

QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: rgba(255,255,255,0.22); border-radius: 4px; min-height: 30px; }}
QScrollBar::handle:vertical:hover {{ background: rgba(255,255,255,0.35); }}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 2px; }}
QScrollBar::handle:horizontal {{ background: rgba(255,255,255,0.22); border-radius: 4px; min-width: 30px; }}
QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {{ width: 0; }}

QSplitter::handle {{ background: transparent; }}
QSplitter::handle:horizontal {{ width: 8px; }}

QTabWidget::pane {{ border: 1px solid {P.border}; border-radius: 8px; top: -1px; }}
QTabBar::tab {{
    background: transparent; color: {P.secondary}; padding: 7px 14px; border: none;
    border-bottom: 2px solid transparent;
}}
QTabBar::tab:selected {{ color: {P.text}; border-bottom: 2px solid {P.accent}; }}

QCheckBox, QRadioButton {{ spacing: 8px; }}
QCheckBox::indicator, QRadioButton::indicator {{ width: 16px; height: 16px; }}
QCheckBox::indicator {{ border: 1px solid rgba(255,255,255,0.35); border-radius: 4px; background: {P.panel}; }}
QCheckBox::indicator:checked {{ background: {P.accent}; border-color: {P.accent}; }}
QRadioButton::indicator {{ border: 1px solid rgba(255,255,255,0.35); border-radius: 8px; background: {P.panel}; }}
QRadioButton::indicator:checked {{ background: {P.accent}; border: 4px solid #1C1C1E; }}

QSlider::groove:horizontal {{ height: 4px; background: rgba(255,255,255,0.2); border-radius: 2px; }}
QSlider::handle:horizontal {{ width: 14px; height: 14px; margin: -5px 0; background: white; border-radius: 7px; }}
QSlider::sub-page:horizontal {{ background: {P.accent}; border-radius: 2px; }}

QProgressBar {{
    background: rgba(255,255,255,0.15); border: none; border-radius: 3px; height: 6px; text-align: center;
}}
QProgressBar::chunk {{ background: {P.accent}; border-radius: 3px; }}

QMenuBar {{ background: transparent; }}
QMenuBar::item:selected {{ background: {P.panel_strong}; border-radius: 6px; }}
QMenu {{ background: #1C1C1E; border: 1px solid {P.border}; border-radius: 10px; padding: 6px; }}
QMenu::item {{ padding: 6px 24px 6px 12px; border-radius: 6px; }}
QMenu::item:selected {{ background: {P.accent}; }}
QMenu::separator {{ height: 1px; background: {P.border}; margin: 6px 4px; }}

QStatusBar {{ background: transparent; color: {P.secondary}; }}
QToolTip {{ background: #1C1C1E; color: {P.text}; border: 1px solid {P.border}; padding: 4px 6px; }}

QWidget#Pill {{
    background: rgba(40, 40, 46, 0.92);
    border: 1px solid {P.border};
    border-radius: 18px;
}}
QWidget#Banner {{
    background: rgba(255, 214, 10, 0.12);
    border: 1px solid rgba(255, 214, 10, 0.35);
    border-radius: 8px;
}}
QFrame#Divider {{ background: {P.border}; max-height: 1px; min-height: 1px; border: none; }}
"""
