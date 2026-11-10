"""Internal workers for synchronization and backups."""

import fcntl
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from contextlib import closing
from pathlib import Path
from threading import Event

import settings

STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/anki"))
LOG_DIR = Path(os.environ.get("LOG_DIR", "/var/log/anki"))
BIN_DIR = Path(__file__).resolve().parent
STOP = Event()
BACKUP_REQUEST = "backup-request.lock"
SYNC_ACTIVE = "sync-active.lock"
SYNC_DRAIN_TIMEOUT = 60


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


def try_lock(file):
    try:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    return True


def run_sync():
    with (STATE_DIR / BACKUP_REQUEST).open("a+b") as request, (STATE_DIR / SYNC_ACTIVE).open("a+b") as active:
        supervise_sync(request, active)


def supervise_sync(request, active):
    users = None
    child = None
    draining = False
    try:
        while not STOP.is_set():
            pause_requested = not try_lock(request)
            if not pause_requested:
                fcntl.flock(request, fcntl.LOCK_UN)

            if child is not None and child.poll() is not None:
                fcntl.flock(active, fcntl.LOCK_UN)
                child = None
                if not draining and not pause_requested:
                    print("Sync process exited. Retrying shortly.", flush=True)
                    STOP.wait(3)
                draining = False

            if pause_requested and child is not None and not draining:
                # Anki drains HTTP requests on SIGINT and then closes SQLite.
                child.send_signal(signal.SIGINT)
                draining = True
            if pause_requested or draining:
                STOP.wait(0.25)
                continue

            configured = settings.read()["users"]
            if users != configured:
                if child is not None:
                    stop_child(child, signal.SIGINT)
                    fcntl.flock(active, fcntl.LOCK_UN)
                    child = None
                users = configured
                idle = STATE_DIR / "sync-idle"
                if users:
                    idle.unlink(missing_ok=True)
                else:
                    idle.touch()

            if users and child is None and try_lock(active):
                env = {key: value for key, value in os.environ.items()
                       if not re.fullmatch(r"SYNC_USER[0-9]+", key)}
                env["PASSWORDS_HASHED"] = "1"
                for index, (name, password) in enumerate(users.items(), start=1):
                    env[f"SYNC_USER{index}"] = f"{name}:{password}"
                # Keep the lock even if the supervisor exits before Anki does.
                child = subprocess.Popen(["anki-sync-server"], env=env, pass_fds=(active.fileno(),))

            STOP.wait(1)
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


def snapshot_with_sync_paused(source, destination, backup_dir):
    print("Waiting for Anki Sync to release the database locks.", flush=True)
    deadline = time.monotonic() + SYNC_DRAIN_TIMEOUT
    # The request makes the supervisor drain Anki. The active lock guarantees
    # that Anki has exited before we read any data and cannot reopen it mid-copy.
    with (STATE_DIR / BACKUP_REQUEST).open("a+b") as request, (STATE_DIR / SYNC_ACTIVE).open("a+b") as active:
        for lock in (request, active):
            while not try_lock(lock):
                if STOP.wait(0.25):
                    raise InterruptedError("Backup interrupted by container shutdown.")
                if time.monotonic() >= deadline:
                    raise TimeoutError("Anki Sync is still finishing an active request. Try again later.")
        if STOP.is_set():
            raise InterruptedError("Backup interrupted by container shutdown.")
        print("Copying Anki collections and media.", flush=True)
        snapshot(source, destination, backup_dir)
    print("Local snapshot complete. Sync can resume while the archive is being written.", flush=True)


def snapshot(source, destination, backup_dir=None):
    if not source.is_dir() or destination.is_relative_to(source):
        raise ValueError("The Anki data directory and backup destination must be separate.")

    backup_stat = backup_dir.stat() if backup_dir is not None else None
    if backup_stat is not None and os.path.samestat(source.stat(), backup_stat):
        raise ValueError("The backup folder cannot be the Anki data folder.")

    def fail_on_walk_error(error):
        raise error

    for parent, directories, files in os.walk(source, onerror=fail_on_walk_error):
        root = Path(parent)
        directories[:] = [
            name for name in directories if not (root / name).is_symlink()
            and (backup_stat is None or not os.path.samestat((root / name).stat(), backup_stat))
        ]
        target = destination / root.relative_to(source)
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            if STOP.is_set():
                raise InterruptedError("Backup interrupted by container shutdown.")
            path = root / name
            if path.is_symlink() or not path.is_file() or name.endswith(("-wal", "-shm", "-journal")):
                continue
            if path.suffix in {".anki2", ".db"}:
                deadline = time.monotonic() + 60

                def check_deadline(_status, _remaining, _total):
                    if STOP.is_set():
                        raise InterruptedError("Backup interrupted by container shutdown.")
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"SQLite snapshot timed out for {path.name}")

                with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)) as database:
                    with closing(sqlite3.connect(target / name)) as copy:
                        database.backup(copy, pages=256, progress=check_deadline)
            else:
                shutil.copy2(path, target / name)


def main():
    command, *args = sys.argv[1:]
    if command == "init":
        try:
            settings.initialize()
        except ValueError as error:
            sys.exit(str(error))
    elif command == "sync":
        run_sync()
    elif command == "backups":
        run_backups()
    elif command == "snapshot":
        try:
            snapshot_with_sync_paused(*(Path(arg).resolve() for arg in args))
        except (OSError, ValueError, sqlite3.Error) as error:
            sys.exit(f"Backup snapshot failed: {error}")
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
