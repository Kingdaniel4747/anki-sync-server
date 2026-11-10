"""Internal workers for synchronization, backups and notifications."""

import json
import os
import re
import shutil
import signal
import smtplib
import sqlite3
import ssl
import subprocess
import sys
import time
from contextlib import closing
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path
from threading import Event
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import settings

STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/anki"))
LOG_DIR = Path(os.environ.get("LOG_DIR", "/var/log/anki"))
BIN_DIR = Path(__file__).resolve().parent
STOP = Event()


def shutdown(*_args):
    STOP.set()


def stop_child(child, sig=signal.SIGTERM, timeout=8):
    if child.poll() is not None:
        return
    child.send_signal(sig)
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def run_sync():
    active = None
    child = None
    try:
        while not STOP.is_set():
            users = settings.read()["users"]
            if active != users:
                if child is not None:
                    stop_child(child, signal.SIGINT)
                active = users
                # Keep the existing metrics reader and external health check usable.
                names = STATE_DIR / "users.txt.tmp"
                names.write_text("".join(name + "\n" for name in users), encoding="utf-8")
                names.replace(STATE_DIR / "users.txt")
                idle = STATE_DIR / "sync-idle"
                if users:
                    idle.unlink(missing_ok=True)
                else:
                    idle.touch()

            if users and (child is None or child.poll() is not None):
                env = {key: value for key, value in os.environ.items()
                       if not re.fullmatch(r"SYNC_USER[0-9]+", key)}
                env["PASSWORDS_HASHED"] = "1"
                for index, (name, password) in enumerate(users.items(), start=1):
                    env[f"SYNC_USER{index}"] = f"{name}:{password}"
                child = subprocess.Popen(["anki-sync-server"], env=env)

            if STOP.wait(2):
                break
            if child is not None and child.poll() is not None and users:
                print("Sync process exited. Retrying shortly.", flush=True)
                STOP.wait(3)
    finally:
        if child is not None:
            stop_child(child, signal.SIGINT)


def claim_backup(now):
    with settings.edit() as state:
        options = state["options"]
        schedule_invalid = False
        if options["BACKUP_ENABLED"] == "true":
            try:
                due = state["next_backup"]
                if due is None or due <= now:
                    state["next_backup"] = settings.next_backup(options, now)
                if due is not None and due <= now and state["backup_job"] is None:
                    state["backup_job"] = "scheduled"
            except (ValueError, KeyError):
                schedule_invalid = True
        return state["backup_job"], options, schedule_invalid


def managed_environment(options):
    return {**os.environ, **options, "ANKI_MANAGED_ENV": "1"}


def run_backups():
    # If the container stops during a backup, the outstanding request survives.
    warned = False
    with (LOG_DIR / "backup.log").open("a", encoding="utf-8") as log:
        while not STOP.is_set():
            job, options, schedule_invalid = claim_backup(time.time())
            if schedule_invalid and not warned:
                print("Invalid backup schedule or time zone. Correct it in the dashboard.", file=log, flush=True)
            warned = schedule_invalid
            if job is None:
                STOP.wait(2)
                continue

            child = subprocess.Popen(
                [str(BIN_DIR / "backup.sh")], env=managed_environment(options),
                stdout=log, stderr=log, start_new_session=True,
            )
            deadline = time.monotonic() + 6 * 3600
            while child.poll() is None and not STOP.wait(1) and time.monotonic() < deadline:
                pass
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            if STOP.is_set() or child.returncode == 75:
                # 75 means another invocation already holds the backup lock.
                STOP.wait(5)
                continue
            with settings.edit() as state:
                state["backup_job"] = None
                state["last_backup"] = {
                    "success": child.returncode == 0,
                    "time": time.time(),
                }
                # Skip intervals that elapsed while this backup was running.
                now = time.time()
                if state["next_backup"] is not None and state["next_backup"] <= now:
                    state["next_backup"] = settings.next_backup(state["options"], now)


def snapshot(source, destination):
    if not source.is_dir() or destination.is_relative_to(source):
        raise ValueError("The Anki data directory and backup destination must be separate.")

    def fail_on_walk_error(error):
        raise error

    for parent, directories, files in os.walk(source, onerror=fail_on_walk_error):
        root = Path(parent)
        directories[:] = [name for name in directories if not (root / name).is_symlink()]
        target = destination / root.relative_to(source)
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            path = root / name
            if path.is_symlink() or not path.is_file() or name.endswith(("-wal", "-shm", "-journal")):
                continue
            if path.suffix in {".anki2", ".db"}:
                deadline = time.monotonic() + 60

                def check_deadline(_status, _remaining, _total):
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"SQLite snapshot timed out for {path.name}")

                with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)) as database:
                    with closing(sqlite3.connect(target / name)) as copy:
                        database.backup(copy, pages=256, progress=check_deadline)
            else:
                shutil.copy2(path, target / name)


def send_webhook(options, message, title):
    kind = options["NOTIFY_TYPE"]
    text = f"{title}: {message}"
    payload = {
        "discord": {"content": text},
        "telegram": {"text": text},
        "slack": {"text": text},
        "ntfy": {"title": title, "message": message},
        "generic": {"title": title, "message": message},
    }[kind]
    url = options["NOTIFY_WEBHOOK_URL"]
    if kind == "telegram":
        data, headers = urlencode({"text": text}).encode(), {"Content-Type": "application/x-www-form-urlencoded"}
    elif kind == "ntfy":
        data, headers = message.encode(), {"Title": title}
    else:
        data, headers = json.dumps(payload).encode(), {"Content-Type": "application/json"}
    with urlopen(Request(url, data=data, headers=headers, method="POST"), timeout=10):
        pass


def send_email(options, message, title):
    mail = EmailMessage()
    mail["Subject"] = title
    mail["From"] = options["EMAIL_FROM"]
    mail["To"] = options["EMAIL_TO"]
    mail.set_content(message)
    context = ssl.create_default_context()
    mode = options["EMAIL_TLS"]
    args = (options["EMAIL_HOST"], int(options["EMAIL_PORT"]))
    connection = (smtplib.SMTP_SSL(*args, timeout=10, context=context) if mode == "implicit"
                  else smtplib.SMTP(*args, timeout=10))
    with connection as smtp:
        if mode == "on":
            smtp.starttls(context=context)
        if options["EMAIL_USER"]:
            smtp.login(options["EMAIL_USER"], options["EMAIL_PASS"])
        smtp.send_message(mail)


def notify(options, message, title):
    outcomes = []
    for flag, name, send in (
        ("NOTIFY_ENABLED", "Webhook", send_webhook),
        ("EMAIL_ENABLED", "Email", send_email),
    ):
        if options[flag] != "true":
            continue
        try:
            send(options, message, title)
            outcomes.append((True, f"{name} sent."))
        except (OSError, ValueError, KeyError) as error:
            # Transport exceptions can include credentials or secret endpoint paths.
            outcomes.append((False, f"{name} failed ({type(error).__name__})."))
    if not outcomes:
        return False, "Enable a webhook or email first."
    return all(ok for ok, _ in outcomes), " ".join(detail for _, detail in outcomes)


def main():
    command, *args = sys.argv[1:]
    if command == "init":
        settings.initialize()
        state = settings.read()
        if state["setup_token"] and os.environ.get("DASHBOARD_ENABLED", "true") == "true":
            print("Dashboard one-time setup token:", state["setup_token"], flush=True)
        if not state["users"] and os.environ.get("DASHBOARD_ENABLED", "true") != "true":
            sys.exit("Enable the dashboard for setup or provide an initial SYNC_USER1.")
    elif command == "sync":
        run_sync()
    elif command == "backups":
        run_backups()
    elif command == "snapshot":
        snapshot(*(Path(arg).resolve() for arg in args))
    elif command == "notify":
        message, title = args
        ok, detail = notify(settings.read()["options"], message, title)
        print(detail)
        return 0 if ok else 1
    elif command == "with-settings":
        script, *arguments = args
        env = managed_environment(settings.read()["options"])
        os.execve(script, [script, *arguments], env)
    else:
        sys.exit(f"Unknown service command: {command}")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    sys.exit(main())
