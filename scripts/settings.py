"""Persistent dashboard and service configuration."""

import base64
import hashlib
import json
import os
import re
import secrets
import sqlite3
from contextlib import closing, contextmanager
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from croniter import croniter
from werkzeug.security import check_password_hash, generate_password_hash

DIRECTORY = Path(os.environ.get("CONFIG_DIR", "/config")) / "management"
DATABASE = DIRECTORY / "settings.sqlite3"
USERNAME_PATTERN = re.compile(r"[A-Za-z0-9_@.+ -]{1,80}")
OPTIONS = {
    "BACKUP_ENABLED": ("Automatic backups", "bool", "false"),
    "BACKUP_SCHEDULE": ("Schedule (five cron fields)", "text", "0 3 * * *"),
    "BACKUP_TIMEZONE": ("Backup time zone (IANA)", "text", "UTC"),
    "BACKUP_RETENTION_DAYS": ("Retention (days)", "number", "7"),
}
SCHEDULE_FIELDS = ("BACKUP_ENABLED", "BACKUP_SCHEDULE", "BACKUP_TIMEZONE")


def read():
    with closing(sqlite3.connect(DATABASE)) as connection:
        return json.loads(connection.execute("SELECT value FROM settings").fetchone()[0])


@contextmanager
def edit():
    with closing(sqlite3.connect(DATABASE)) as connection, connection:
        connection.execute("BEGIN IMMEDIATE")
        original = connection.execute("SELECT value FROM settings").fetchone()[0]
        state = json.loads(original)
        yield state
        if (updated := json.dumps(state)) != original:
            connection.execute("UPDATE settings SET value = ?", (updated,))


def password_hash(password):
    # Anki's Rust sync server accepts this PBKDF2 PHC representation.
    salt = os.urandom(16)
    rounds = 600_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, rounds)
    salt_b64 = base64.b64encode(salt).decode().rstrip("=")
    digest_b64 = base64.b64encode(digest).decode().rstrip("=")
    return "$".join(("", "pbkdf2-sha256", f"i={rounds},l=32", salt_b64, digest_b64))


def valid_username(username):
    return bool(USERNAME_PATTERN.fullmatch(username)) and username == username.strip() and username not in {".", ".."}


def next_backup(options, after):
    local = datetime.fromtimestamp(after, ZoneInfo(options["BACKUP_TIMEZONE"]))
    return croniter(options["BACKUP_SCHEDULE"], local).get_next()


def validate_options(options):
    for key, value in options.items():
        if len(value) > 4096 or any(char in value for char in "\r\n\0"):
            raise ValueError(f"Invalid value for {OPTIONS[key][0]}.")
    retention = options["BACKUP_RETENTION_DAYS"]
    if not re.fullmatch(r"[0-9]{1,5}", retention) or not 1 <= int(retention) <= 36500:
        raise ValueError("Retention must be between 1 and 36500 days.")
    try:
        ZoneInfo(options["BACKUP_TIMEZONE"])
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError("Enter an IANA time zone such as Europe/Berlin.") from None
    schedule = options["BACKUP_SCHEDULE"]
    if len(schedule.split()) != 5 or not re.fullmatch(r"[-a-zA-Z0-9,*/ ]{9,120}", schedule) or not croniter.is_valid(schedule):
        raise ValueError("Enter a five-field cron schedule such as 0 3 * * *.")
    try:
        next_backup(options, datetime.now().timestamp())
    except ValueError:
        raise ValueError("The schedule has no upcoming run.") from None


def valid_admin_sync_username(username):
    # The upstream server uses this name as a single directory within /data.
    return (
        bool(username) and username == username.strip()
        and username not in {".", ".."}
        and len(username.encode()) <= 255
        and not any(char in username for char in "/\\:\0\r\n")
    )


def set_admin_sync_password(state, password):
    admin = state["admin"]
    username = admin["username"]
    # Older dashboards could accept names that cannot be used for sync.
    if valid_admin_sync_username(username):
        state["users"][username] = password_hash(password)
        admin["sync_enabled"] = True


def initial_admin(state):
    username, separator, password = os.environ.get("DASHBOARD_AUTH", "").partition(":")
    if not separator or not username or not password:
        raise ValueError("Set DASHBOARD_AUTH=username:password in Docker before starting with a new config volume.")
    if not valid_admin_sync_username(username):
        raise ValueError("Choose an administrator name that can also be used as an Anki sync username.")
    if not 12 <= len(password) <= 256:
        raise ValueError("Use an administrator password with 12 to 256 characters.")
    state["admin"] = {"username": username, "hash": generate_password_hash(password)}
    set_admin_sync_password(state, password)


def initialize():
    # The database and rollback journal live inside this private directory.
    DIRECTORY.mkdir(parents=True, mode=0o700, exist_ok=True)
    with closing(sqlite3.connect(DATABASE)) as connection, connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("CREATE TABLE IF NOT EXISTS settings (value TEXT NOT NULL)")
        row = connection.execute("SELECT value FROM settings").fetchone()
        if row:
            state = json.loads(row[0])
            if not state["admin"]:
                initial_admin(state)
            elif not state["admin"].get("sync_enabled"):
                admin = state["admin"]
                username, _, password = os.environ.get("DASHBOARD_AUTH", "").partition(":")
                if username == admin["username"] and check_password_hash(admin["hash"], password):
                    set_admin_sync_password(state, password)
            state.pop("setup_token", None)
            state["options"] = {key: state["options"].get(key, default)
                                for key, (_, _, default) in OPTIONS.items()}
            updated = json.dumps(state)
            if updated != row[0]:
                connection.execute("PRAGMA secure_delete = ON")
                connection.execute("UPDATE settings SET value = ?", (updated,))
            return

        users = {}
        hashed = os.environ.get("PASSWORDS_HASHED") in {"true", "1"}
        variables = [key for key in os.environ if re.fullmatch(r"SYNC_USER[0-9]+", key)]
        for key in sorted(variables, key=lambda key: int(key[9:])):
            username, separator, password = os.environ[key].partition(":")
            # Accept existing Unicode and punctuation in a single directory name.
            if not separator or not username or not password or username in {".", ".."} or any(c in username for c in "/\\\r\n"):
                raise ValueError(f"Invalid legacy user in {key}.")
            users[username] = password if hashed else password_hash(password)

        options = {key: os.environ.get(key, default) for key, (_, _, default) in OPTIONS.items()}
        options["BACKUP_TIMEZONE"] = os.environ.get("BACKUP_TIMEZONE") or os.environ.get("TZ", "UTC")
        for key, (_, kind, _) in OPTIONS.items():
            if kind == "bool":
                options[key] = str(options[key].lower() in {"true", "1"}).lower()

        state = {
            "session_key": secrets.token_hex(32), "users": users, "options": options,
            "next_backup": None, "backup_job": None, "last_backup": None,
        }
        initial_admin(state)
        connection.execute("INSERT INTO settings VALUES (?)", (json.dumps(state),))
