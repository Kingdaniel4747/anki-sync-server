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
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from croniter import croniter
from werkzeug.security import generate_password_hash

DIRECTORY = Path(os.environ.get("CONFIG_DIR", "/config")) / "management"
DATABASE = DIRECTORY / "settings.sqlite3"
USERNAME_PATTERN = re.compile(r"[A-Za-z0-9_@.+ -]{1,80}")
OPTIONS = {
    "BACKUP_ENABLED": ("Automatic backups", "bool", "false"),
    "BACKUP_SCHEDULE": ("Schedule (five cron fields)", "text", "0 3 * * *"),
    "BACKUP_TIMEZONE": ("Backup time zone (IANA)", "text", "UTC"),
    "BACKUP_RETENTION_DAYS": ("Retention (days)", "number", "7"),
    "S3_BACKUP_ENABLED": ("Upload to S3", "bool", "false"),
    "S3_ENDPOINT": ("Custom S3 endpoint", "url", ""),
    "S3_BUCKET": ("Bucket", "text", ""),
    "S3_REGION": ("Region", "text", "us-east-1"),
    "S3_ACCESS_KEY": ("Access key", "secret", ""),
    "S3_SECRET_KEY": ("Secret key", "secret", ""),
    "NOTIFY_ENABLED": ("Send webhook notifications", "bool", "false"),
    "NOTIFY_TYPE": ("Webhook type", "select", "discord"),
    "NOTIFY_WEBHOOK_URL": ("Webhook URL", "secret", ""),
    "EMAIL_ENABLED": ("Send email notifications", "bool", "false"),
    "EMAIL_HOST": ("SMTP host", "text", ""),
    "EMAIL_PORT": ("SMTP port", "number", "587"),
    "EMAIL_USER": ("SMTP username", "text", ""),
    "EMAIL_PASS": ("SMTP password", "secret", ""),
    "EMAIL_FROM": ("From address", "text", ""),
    "EMAIL_TO": ("To address", "text", ""),
    "EMAIL_TLS": ("SMTP security", "select", "on"),
}
CHOICES = {
    "NOTIFY_TYPE": {
        "discord": "Discord", "telegram": "Telegram", "slack": "Slack",
        "ntfy": "ntfy", "generic": "Generic JSON",
    },
    "EMAIL_TLS": {"on": "STARTTLS", "implicit": "TLS", "off": "Unencrypted"},
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
        if key in CHOICES and value not in CHOICES[key]:
            raise ValueError(f"Invalid choice for {OPTIONS[key][0]}.")
    for key, minimum, maximum in (("BACKUP_RETENTION_DAYS", 1, 36500), ("EMAIL_PORT", 1, 65535)):
        value = options[key]
        if not re.fullmatch(r"[0-9]{1,5}", value) or not minimum <= int(value) <= maximum:
            raise ValueError(f"{OPTIONS[key][0]} must be between {minimum} and {maximum}.")
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

    for key in ("S3_ENDPOINT", "NOTIFY_WEBHOOK_URL"):
        if options[key]:
            url = urlsplit(options[key])
            if url.scheme not in {"http", "https"} or not url.hostname:
                raise ValueError(f"{OPTIONS[key][0]} must be an HTTP(S) URL.")
    for toggle, required in (
        ("S3_BACKUP_ENABLED", ("S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY")),
        ("NOTIFY_ENABLED", ("NOTIFY_WEBHOOK_URL",)),
        ("EMAIL_ENABLED", ("EMAIL_HOST", "EMAIL_FROM", "EMAIL_TO")),
    ):
        if options[toggle] == "true" and any(not options[key] for key in required):
            raise ValueError(f"Fill in the connection details before enabling {OPTIONS[toggle][0].lower()}.")


def initialize():
    # The database and rollback journal live inside this private directory.
    DIRECTORY.mkdir(parents=True, mode=0o700, exist_ok=True)
    with closing(sqlite3.connect(DATABASE)) as connection, connection:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute("CREATE TABLE IF NOT EXISTS settings (value TEXT NOT NULL)")
        if connection.execute("SELECT 1 FROM settings").fetchone():
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

        admin = None
        auth = os.environ.get("DASHBOARD_AUTH", "")
        if auth:
            username, separator, password = auth.partition(":")
            if not separator or not username or not password:
                raise ValueError("DASHBOARD_AUTH must contain username:password.")
            admin = {"username": username, "hash": generate_password_hash(password)}

        options = {key: os.environ.get(key, default) for key, (_, _, default) in OPTIONS.items()}
        options["BACKUP_TIMEZONE"] = os.environ.get("BACKUP_TIMEZONE") or os.environ.get("TZ", "UTC")
        for key, (_, kind, _) in OPTIONS.items():
            if kind == "bool":
                options[key] = str(options[key].lower() in {"true", "1"}).lower()

        state = {
            "admin": admin, "setup_token": None if admin else secrets.token_urlsafe(24),
            "session_key": secrets.token_hex(32), "users": users, "options": options,
            "next_backup": None, "backup_job": None, "last_backup": None,
        }
        connection.execute("INSERT INTO settings VALUES (?)", (json.dumps(state),))
