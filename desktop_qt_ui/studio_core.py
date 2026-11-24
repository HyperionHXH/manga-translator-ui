"""The desktop's one owned batch worker. No listener or shared service."""
import json
import logging
from pathlib import Path
import sys

from PyQt6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, pyqtSignal

FRAME = b"STUDIO/1 "
LOGGER = logging.getLogger("studio.core")

LEVELS = {name: level for name, level in (("DEBUG", logging.DEBUG), ("INFO", logging.INFO),
                                        ("WARNING", logging.WARNING), ("ERROR", logging.ERROR))}

class StudioCore(QObject):
    changed = pyqtSignal()
    progress = pyqtSignal(int, int, str)
    settled = pyqtSignal(str, object)
    fault = pyqtSignal(str)

    def __init__(self, root, parent=None):
        super().__init__(parent)
        self.state = "off"
        self.busy = False
        self._exit_message = ""
        self._stdout = bytearray()
        self._stderr = bytearray()
        self._process = QProcess(self)
        self._process.setWorkingDirectory(str(root))
        program = Path(sys.executable)
        if program.name.lower() == "pythonw.exe":
            program = program.with_name("python.exe")
        self._process.setProgram(str(program))
        self._process.setArguments(["-B", "-u", str(Path(__file__).with_name("studio_worker.py"))])
        env = QProcessEnvironment.systemEnvironment()
        env.insert("QT_QPA_PLATFORM", "offscreen")
        env.insert("PYTHONIOENCODING", "utf-8")
        env.insert("MANGA_TRANSLATOR_ENV_PATH", str(Path(root) / ".env"))
        self._process.setProcessEnvironment(env)
        self._process.readyReadStandardOutput.connect(self._read_stdout)
        self._process.readyReadStandardError.connect(self._read_stderr)
        self._process.errorOccurred.connect(self._process_error)
        self._process.finished.connect(self._process_finished)
        self._startup = QTimer(self, singleShot=True, interval=180000)
        self._startup.timeout.connect(self._startup_timeout)

    def _set_state(self, state):
        self.state = state
        self.changed.emit()

    def start(self):
        if self.state not in {"off", "failed"} or self._process.state() != QProcess.ProcessState.NotRunning:
            return
        self._stdout.clear()
        self._stderr.clear()
        self._exit_message = ""
        self._set_state("starting")
        self._startup.start()
        self._process.start()

    def run(self, files, config, output, folders):
        if self.state != "ready" or self.busy:
            return False
        self.busy = True
        self.changed.emit()
        return self._send(dict(command="run", files=files, config=config, output=output, folders=folders))

    def cancel(self):
        if self.busy:
            self._send({"command": "cancel"})

    def stop(self):
        if self.state not in {"starting", "ready"}:
            return
        self._set_state("stopping")
        if not self.busy and not self._startup.isActive():
            self._shutdown()

    def _shutdown(self):
        self._send({"command": "shutdown"})
        self._process.closeWriteChannel()

    def _send(self, data):
        raw = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf8") + b"\n"
        if self._process.write(raw) == len(raw):
            return True
        # Do not retry a command that may already have started a paid request.
        self._exit_message = "Communication with the translation core failed. Inspect the saved output before retrying."
        self._process.closeWriteChannel()
        return False

    def _read_stdout(self):
        self._stdout.extend(bytes(self._process.readAllStandardOutput()))
        while (end := self._stdout.find(b"\n")) >= 0:
            line = bytes(self._stdout[:end])
            del self._stdout[:end + 1]
            if not line.startswith(FRAME):
                if line.strip():
                    LOGGER.info("%s", line.decode("utf8", "replace"))
                continue
            try:
                kind, value = json.loads(line[len(FRAME):])
                if kind == "ready" and self.state in {"starting", "stopping"}:
                    self._startup.stop()
                    if self.state == "starting":
                        self._set_state("ready")
                    else:
                        self._shutdown()
                elif kind == "progress" and self.busy:
                    self.progress.emit(*value)
                elif kind in {"done", "error", "cancelled"} and self.busy:
                    self._settle(kind, value)
                elif kind == "fatal":
                    self._exit_message = str(value)
            except (ValueError, TypeError):
                self._exit_message = "The translation core sent an invalid message. Inspect the saved output before retrying."
                self._process.closeWriteChannel()

    def _read_stderr(self):
        self._stderr.extend(bytes(self._process.readAllStandardError()))
        while (end := self._stderr.find(b"\n")) >= 0:
            line = bytes(self._stderr[:end]).rstrip().decode("utf8", "replace")
            del self._stderr[:end + 1]
            if line:
                level, _, message = line.partition(" ")
                LOGGER.log(LEVELS[level], "%s", message) if level in LEVELS else LOGGER.info("%s", line)

    def _settle(self, kind, value):
        self.busy = False
        self.settled.emit(kind, value)
        self.changed.emit()
        if self.state == "stopping":
            self._shutdown()

    def _startup_timeout(self):
        self._exit_message = "The translation core did not become ready. See Logs for details."
        self._process.kill()

    def _process_error(self, error):
        if error == QProcess.ProcessError.FailedToStart:
            self._startup.stop()
            self._set_state("failed")
            self.fault.emit(self._process.errorString())

    def _process_finished(self, code, status):
        self._read_stdout()
        self._read_stderr()
        if self._stderr:
            LOGGER.info("%s", bytes(self._stderr).decode("utf8", "replace"))
            self._stderr.clear()
        self._startup.stop()
        normal = not self.busy and not self._exit_message and self.state == "stopping" and code == 0 and status == QProcess.ExitStatus.NormalExit
        if normal:
            self._set_state("off")
            return
        message = self._exit_message or f"The translation core exited unexpectedly ({code}). See Logs and inspect the output before retrying."
        was_busy = self.busy
        self._set_state("failed")
        if was_busy:
            self._settle("error", message)
        else:
            self.fault.emit(message)
