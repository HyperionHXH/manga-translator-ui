"""Control center and logs for the desktop batch core; no persistent library."""
from datetime import timedelta
from pathlib import Path
import time

from PyQt6.QtCore import QTimer, QUrl
from PyQt6.QtGui import QDesktopServices
from PyQt6.QtWidgets import QApplication, QHBoxLayout, QPlainTextEdit, QVBoxLayout, QWidget
from qfluentwidgets import BodyLabel, CaptionLabel, ComboBox, HeaderCardWidget, PrimaryPushButton, ProgressBar, PushButton, SubtitleLabel, TitleLabel

from services import ServiceManager


class StudioOverview(QWidget):
    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self.logic = window.app_logic
        self.core = self.logic.studio_core
        self.started = None
        self.elapsed = 0
        self.last_progress = 0
        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 22, 28, 26)
        layout.setSpacing(16)
        self.title = TitleLabel("Manga Studio")
        self.subtitle = BodyLabel()
        self.subtitle.setWordWrap(True)
        layout.addWidget(self.title)
        layout.addWidget(self.subtitle)

        self.core_card = HeaderCardWidget()
        self.core_status = SubtitleLabel()
        self.core_hint = CaptionLabel()
        self.core_hint.setWordWrap(True)
        self.core_card.viewLayout.addWidget(self.core_status)
        self.core_card.viewLayout.addWidget(self.core_hint)
        actions = QHBoxLayout()
        self.start_button = PrimaryPushButton()
        self.stop_button = PushButton()
        self.workspace_button = PushButton()
        actions.addWidget(self.start_button)
        actions.addWidget(self.stop_button)
        actions.addStretch()
        actions.addWidget(self.workspace_button)
        self.core_card.viewLayout.addLayout(actions)
        layout.addWidget(self.core_card)

        self.task_card = HeaderCardWidget()
        self.task_status = BodyLabel()
        self.task_status.setWordWrap(True)
        self.progress = ProgressBar()
        self.progress.setRange(0, 100)
        self.detail = CaptionLabel()
        self.detail.setWordWrap(True)
        self.task_card.viewLayout.addWidget(self.task_status)
        self.task_card.viewLayout.addWidget(self.progress)
        self.task_card.viewLayout.addWidget(self.detail)
        task_actions = QHBoxLayout()
        self.cancel_button = PushButton()
        self.output_button = PushButton()
        task_actions.addWidget(self.cancel_button)
        task_actions.addWidget(self.output_button)
        task_actions.addStretch()
        self.task_card.viewLayout.addLayout(task_actions)
        layout.addWidget(self.task_card)
        layout.addStretch()

        self.start_button.clicked.connect(self.core.start)
        self.stop_button.clicked.connect(self.core.stop)
        self.cancel_button.clicked.connect(self.logic.stop_task)
        self.output_button.clicked.connect(self.logic.open_output_folder)
        self.workspace_button.clicked.connect(lambda: window._switch_main_page("translation"))
        self.core.changed.connect(self.refresh)
        self.logic.state_manager.is_translating_changed.connect(self._on_task_state)
        self.logic.state_manager.status_message_changed.connect(self.refresh)
        self.logic.state_manager.translation_progress_changed.connect(self._on_progress)
        self.logic.file_sources_changed.connect(self.refresh)
        self.logic.output_path_updated.connect(self.refresh)
        self.timer = QTimer(self, interval=1000)
        self.timer.timeout.connect(self.refresh)
        self.refresh()

    def text(self, zh, en):
        return zh if self.window.i18n.get_current_locale().startswith("zh") else en

    def _on_task_state(self, running):
        if running:
            self.started = time.monotonic()
            self.last_progress = 0
            self.elapsed = 0
            self.timer.start()
        elif self.started is not None:
            self.elapsed = time.monotonic() - self.started
            self.started = None
            self.timer.stop()
        self.refresh()

    def _on_progress(self, progress):
        self.last_progress = round(progress)
        self.refresh()

    def refresh(self, *_):
        t = self.text
        state = self.core.state
        labels = {"off": t("核心未启动", "Core off"), "starting": t("正在启动核心", "Starting core"),
                  "ready": t("核心已就绪", "Core ready"), "stopping": t("正在停止核心", "Stopping core"),
                  "failed": t("核心异常退出", "Core stopped unexpectedly")}
        self.subtitle.setText(t("本地文件翻译工作台 · 检测、OCR、翻译、修图和编辑", "Local file workspace · detect, recognize, translate, clean and edit"))
        self.core_card.setTitle(t("批量翻译核心", "Batch translation core"))
        self.task_card.setTitle(t("当前任务", "Current task"))
        self.core_status.setText(labels[state])
        self.core_hint.setText(t("核心按需启动。停止核心会等当前批量任务结束；立即取消请用下方停止任务。",
                                 "The core starts on demand. Stop Core drains the current batch; use Stop Task to cancel it."))
        self.start_button.setText(t("启动核心", "Start Core"))
        self.stop_button.setText(t("停止核心", "Stop Core"))
        self.workspace_button.setText(t("打开翻译工作台", "Open Translation Workspace"))
        self.cancel_button.setText(t("停止任务", "Stop Task"))
        self.output_button.setText(t("打开输出目录", "Open Output Folder"))
        running = self.logic.state_manager.is_translating()
        self.start_button.setEnabled(state in {"off", "failed"} and not running)
        self.stop_button.setEnabled(state in {"starting", "ready"} and (not running or self.core.busy))
        self.cancel_button.setEnabled(running)
        output = self.logic.config_service.get_config().app.last_output_path
        self.output_button.setEnabled(bool(output) and Path(output).is_dir())
        status = self.logic.state_manager.get_status_message()
        self.task_status.setText(status if running or self.started is not None or self.elapsed else t("尚无运行中的批量任务", "No batch task running"))
        self.progress.setValue(self.last_progress)
        elapsed = self.elapsed if self.started is None else time.monotonic() - self.started
        self.detail.setText(t("输入项", "Inputs") + f"  {len(self.logic.source_files)}    ·    " + t("耗时", "Elapsed") + f"  {timedelta(seconds=int(elapsed))}")


class StudioLogs(QWidget):
    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self._displayed = None
        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 22, 28, 26)
        layout.setSpacing(12)
        self.title = TitleLabel()
        layout.addWidget(self.title)
        actions = QHBoxLayout()
        self.level = ComboBox()
        self.level.addItems(["ALL", "INFO", "WARNING", "ERROR", "DEBUG"])
        self.copy_button = PushButton()
        self.folder_button = PushButton()
        actions.addWidget(self.level)
        actions.addWidget(self.copy_button)
        actions.addWidget(self.folder_button)
        actions.addStretch()
        layout.addLayout(actions)
        self.output = QPlainTextEdit(readOnly=True)
        self.output.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        layout.addWidget(self.output, 1)
        self.copy_button.clicked.connect(lambda: QApplication.clipboard().setText(self.output.toPlainText()))
        self.folder_button.clicked.connect(self._open_folder)
        self.level.currentIndexChanged.connect(self.refresh)
        self.timer = QTimer(self, interval=750)
        self.timer.timeout.connect(self.refresh)
        self.refresh_labels()

    def refresh_labels(self):
        zh = self.window.i18n.get_current_locale().startswith("zh")
        self.title.setText("运行日志" if zh else "Run Logs")
        self.copy_button.setText("复制当前日志" if zh else "Copy Visible Logs")
        self.folder_button.setText("打开日志目录" if zh else "Open Log Folder")

    def showEvent(self, event):
        super().showEvent(event)
        self.refresh()
        self.timer.start()

    def hideEvent(self, event):
        self.timer.stop()
        super().hideEvent(event)

    def _open_folder(self):
        root = Path(self.window.config_service.root_dir)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(root / "result")))

    def refresh(self, *_):
        log = ServiceManager.get_log_service()
        if not log:
            return
        level = self.level.currentText()
        items = log.get_recent_logs(level=None if level == "ALL" else level, limit=350)
        if items == self._displayed:
            return
        self._displayed = items
        scroll = self.output.verticalScrollBar()
        position = scroll.value()
        follow = position == scroll.maximum()
        self.output.setPlainText("\n".join(f"{x['timestamp'][11:19]}  {x['level']}  [{x['module']}]  {x['message']}" for x in items))
        scroll.setValue(scroll.maximum() if follow else position)
