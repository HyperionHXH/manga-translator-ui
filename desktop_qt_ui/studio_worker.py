"""Private runner for the desktop batch workflow, using the upstream worker unchanged."""
import asyncio
import json
import logging
import os
from pathlib import Path
import sys
from threading import Thread

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def main():
    wire = sys.stdout.buffer
    sys.stdout = sys.stderr
    os.environ.setdefault("MANGA_TRANSLATOR_ENV_PATH", str(ROOT / ".env"))
    inherited = dict(os.environ)

    def send(kind, value=None):
        wire.write(b"STUDIO/1 " + json.dumps([kind, value], ensure_ascii=False).encode("utf8") + b"\n")
        wire.flush()

    try:
        # Match the upstream Windows import order to avoid Torch/Qt DLL conflicts.
        import torch  # noqa: F401
        from PyQt6.QtWidgets import QApplication
        from app_logic import TranslationWorker
        from services import init_services, shutdown_services
        from manga_translator.manga_translator import MangaTranslator  # noqa: F401
        from manga_translator.utils.dotenv_utils import read_dotenv_file
        from manga_translator.utils.system_proxy import set_system_proxy_enabled

        app = QApplication([])
        if not init_services(str(ROOT)):
            raise RuntimeError("Cannot initialize Manga Translator services")
        handler = logging.StreamHandler(sys.stderr)
        handler.setFormatter(logging.Formatter("%(levelname)s [%(name)s] %(message)s"))
        logging.getLogger().addHandler(handler)

        async def serve():
            loop = asyncio.get_running_loop()
            commands = asyncio.Queue()

            def read_commands():
                # Consume complete JSON lines while the desktop keeps the pipe open.
                buffer = bytearray()
                try:
                    while chunk := os.read(sys.stdin.fileno(), 65536):
                        buffer.extend(chunk)
                        while (end := buffer.find(b"\n")) >= 0:
                            line = bytes(buffer[:end])
                            del buffer[:end + 1]
                            loop.call_soon_threadsafe(commands.put_nowait, json.loads(line))
                except (OSError, ValueError):
                    logging.exception("Cannot read desktop core commands")
                finally:
                    loop.call_soon_threadsafe(commands.put_nowait, {"command": "shutdown"})

            Thread(target=read_commands, daemon=True, name="studio-commands").start()
            task = None
            worker = None
            closing = False
            cancelled = False
            previous_env = set(read_dotenv_file(os.environ["MANGA_TRANSLATOR_ENV_PATH"]))

            async def run(data):
                nonlocal worker
                results, errors = [], []
                try:
                    if cancelled:
                        send("cancelled")
                        return
                    current_env = read_dotenv_file(os.environ["MANGA_TRANSLATOR_ENV_PATH"])
                    for key in previous_env - current_env.keys():
                        if key in inherited:
                            os.environ[key] = inherited[key]
                        else:
                            os.environ.pop(key, None)
                    previous_env.clear()
                    previous_env.update(current_env)
                    os.environ.update(current_env)
                    set_system_proxy_enabled(bool(data["config"].get("app", {}).get("use_system_proxy")))
                    worker = TranslationWorker(data["files"], data["config"], data["output"], str(ROOT), data["folders"])
                    worker.progress.connect(lambda current, total, message: send("progress", [current, total, message]))
                    worker.finished.connect(results.extend)
                    worker.error.connect(errors.append)
                    await worker._do_processing()
                    if cancelled:
                        send("cancelled")
                    elif errors:
                        send("error", errors[-1])
                    elif results:
                        send("done", results)
                    else:
                        send("error", "The engine returned no page results.")
                except asyncio.CancelledError:
                    send("cancelled")
                except Exception as exc:
                    logging.exception("Core task failed")
                    send("error", str(exc))
                finally:
                    worker = None

            send("ready")
            pending = asyncio.create_task(commands.get())
            try:
                while True:
                    live = {item for item in (pending, task) if item is not None}
                    await asyncio.wait(live, return_when=asyncio.FIRST_COMPLETED)
                    if task is not None and task.done():
                        await task
                        task = None
                    if pending is not None and pending.done():
                        data = pending.result()
                        action = data["command"]
                        if action == "shutdown":
                            pending = None
                            closing = True
                        else:
                            pending = asyncio.create_task(commands.get())
                            if action == "run" and task is None:
                                cancelled = False
                                task = asyncio.create_task(run(data))
                            elif action == "cancel" and task is not None and not cancelled:
                                cancelled = True
                                if worker is not None:
                                    worker._is_running = False
                                    task.cancel()
                                # If it has not entered run() yet, run() observes the flag.
                    if closing and task is None:
                        return
            finally:
                if pending is not None:
                    pending.cancel()

        try:
            asyncio.run(serve())
        finally:
            shutdown_services()
            app.quit()
        return 0
    except (OSError, RuntimeError, ImportError) as exc:
        logging.exception("Translation core failed")
        send("fatal", str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
