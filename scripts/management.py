"""Dashboard login and configuration routes."""

import hashlib
import hmac
import os
import re
import secrets
import time
from datetime import datetime, timedelta
from pathlib import Path
from threading import Lock
from zoneinfo import ZoneInfo

from flask import (
    abort, flash, jsonify, redirect, render_template, request, session, url_for,
)
from werkzeug.security import check_password_hash, generate_password_hash

import settings

WEEKDAYS = ("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")
ATTEMPT_WINDOW = 300
attempts = {}
attempt_lock = Lock()


def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


def same_text(first, second):
    return hmac.compare_digest(first.encode(), second.encode())


def admin_marker(admin):
    return hashlib.sha256(("sync-v1:" + admin["hash"]).encode()).hexdigest()


def start_session(admin):
    session.clear()
    session.permanent = True
    session["admin"] = admin_marker(admin)


def allow_attempt():
    now = time.monotonic()
    address = request.remote_addr
    with attempt_lock:
        for key in list(attempts):
            if attempts[key][0] + ATTEMPT_WINDOW <= now:
                del attempts[key]
        start, count = attempts.get(address, (now, 0))
        if count >= 12 or (address not in attempts and len(attempts) >= 2048):
            return False
        attempts[address] = (start, count + 1)
        return True


def new_password(field="password"):
    password = request.form.get(field, "")
    if not 12 <= len(password) <= 256 or "\0" in password:
        raise ValueError("Use a password with 12 to 256 characters.")
    return password


def schedule_from_form(form):
    kind = form.get("schedule_kind")
    if kind == "custom":
        return " ".join(form.get("BACKUP_SCHEDULE", "").split())
    match = re.fullmatch(r"([01]\d|2[0-3]):([0-5]\d)", form.get("backup_time", ""))
    day = form.get("backup_day", "")
    if not match or kind not in {"daily", "weekly"} or (kind == "weekly" and not re.fullmatch(r"[0-6]", day)):
        raise ValueError("Choose a valid backup time and day.")
    hour, minute = map(int, match.groups())
    return f"{minute} {hour} * * {day if kind == 'weekly' else '*'}"


def save_options(form):
    with settings.edit() as state:
        previous = state["options"]
        options = previous.copy()
        for key, (_, kind, _) in settings.OPTIONS.items():
            if key == "BACKUP_SCHEDULE":
                continue
            value = form.get(key, "")
            if kind == "bool":
                options[key] = "true" if value == "on" else "false"
            else:
                options[key] = value.strip()
        options["BACKUP_SCHEDULE"] = schedule_from_form(form)
        settings.validate_options(options)
        if any(previous[key] != options[key] for key in settings.SCHEDULE_FIELDS):
            state["next_backup"] = (settings.next_backup(options, time.time())
                                    if options["BACKUP_ENABLED"] == "true" else None)
        state["options"] = options


def schedule_view(expression):
    match = re.fullmatch(r"([0-5]?\d) ([01]?\d|2[0-3]) \* \* ([*0-6])", expression)
    if not match:
        return "custom", "03:00", "0"
    minute, hour, day = match.groups()
    return ("daily" if day == "*" else "weekly",
            f"{int(hour):02}:{int(minute):02}", "0" if day == "*" else day)


def display_time(timestamp, zone):
    if timestamp is None:
        return None
    try:
        tz = ZoneInfo(zone)
    except (KeyError, ValueError):
        tz = ZoneInfo("UTC")
    return datetime.fromtimestamp(timestamp, tz).strftime("%Y-%m-%d %H:%M %Z")


def backup_status(state):
    zone = state["options"]["BACKUP_TIMEZONE"]
    last = state["last_backup"]
    last_run = "—"
    if last:
        result = "completed" if last["success"] else "failed, see Backup logs"
        last_run = f"{display_time(last['time'], zone)} · {result}"
    return {
        "next_run": display_time(state["next_backup"], zone) or "—",
        "last_run": last_run,
        "pending": bool(state["backup_job"]),
    }


def dashboard_context(state):
    options = state["options"]
    kind, backup_time, day = schedule_view(options["BACKUP_SCHEDULE"])
    admin = state["admin"]
    username = admin["username"]
    return {
        "users": sorted(name for name in state["users"] if name != username),
        "admin_username": username,
        "admin_sync_enabled": admin.get("sync_enabled", False),
        "options": options,
        "fields": settings.OPTIONS,
        "weekdays": WEEKDAYS,
        "schedule_kind": kind,
        "backup_time": backup_time,
        "backup_day": day,
        **backup_status(state),
    }


def register(app):
    # Settings were initialized by the entrypoint, before Waitress opens the port.
    app.config.update(
        SECRET_KEY=settings.read()["session_key"],
        SESSION_COOKIE_NAME="anki_dashboard_session",
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.environ.get("DASHBOARD_COOKIE_SECURE", "false") == "true",
        SESSION_REFRESH_EACH_REQUEST=False,
        PERMANENT_SESSION_LIFETIME=timedelta(hours=12),
        MAX_CONTENT_LENGTH=64 * 1024,
    )
    app.jinja_env.globals["csrf_token"] = csrf_token
    app.template_folder = str(Path(__file__).with_name("templates"))

    @app.before_request
    def require_session():
        if request.endpoint in {"static_assets", "health"}:
            return None
        if request.method not in {"GET", "HEAD", "OPTIONS"}:
            expected = session.get("csrf", "")
            token = request.headers.get("X-CSRF-Token") or request.form.get("csrf", "")
            if not expected or not same_text(token, expected):
                abort(403)
        if request.endpoint == "login":
            return None
        admin = settings.read()["admin"]
        if admin and session.get("admin") == admin_marker(admin):
            return None
        if request.path.startswith("/api/"):
            return jsonify(error="Sign in to continue."), 401
        return redirect(url_for("login"))

    @app.after_request
    def security_headers(response):
        if request.endpoint != "static_assets":
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["Content-Security-Policy"] = (
                "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
            )
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.route("/login", methods=["GET", "POST"])
    def login():
        admin = settings.read()["admin"]
        if request.method == "POST":
            if not allow_attempt():
                return render_template("login.html", error="Try again in five minutes."), 429
            username = request.form.get("username", "")
            password = request.form.get("password", "")
            if len(password) <= 256 and check_password_hash(admin["hash"], password) and same_text(username, admin["username"]):
                if not admin.get("sync_enabled"):
                    # The old dashboard hash cannot be used by Anki. Link it
                    # using the plaintext from this successful login.
                    with settings.edit() as state:
                        current = state["admin"]
                        if current["hash"] != admin["hash"]:
                            return redirect(url_for("login"))
                        if not current.get("sync_enabled"):
                            settings.set_admin_sync_password(state, password)
                        admin = current
                start_session(admin)
                with attempt_lock:
                    attempts.pop(request.remote_addr, None)
                return redirect(url_for("dashboard"))
            return render_template("login.html", error="Incorrect username or password."), 401
        if session.get("admin") == admin_marker(admin):
            return redirect(url_for("dashboard"))
        return render_template("login.html")

    @app.post("/logout")
    def logout():
        session.clear()
        return redirect(url_for("login"))

    @app.route("/settings", methods=["GET", "POST"])
    def manage():
        if request.method != "POST":
            return redirect(url_for("dashboard", tab="users"))

        action = request.form.get("action")
        tab = "backups" if action == "options" else "users"
        show_add = None
        try:
            if action == "options":
                save_options(request.form)
                flash("Backup schedule saved.", "ok")
            elif action == "admin":
                with settings.edit() as state:
                    admin = state["admin"]
                    if not check_password_hash(admin["hash"], request.form.get("current_password", "")):
                        raise ValueError("The current administrator password is incorrect.")
                    password = new_password()
                    admin["hash"] = generate_password_hash(password)
                    settings.set_admin_sync_password(state, password)
                start_session(admin)
                flash("Administrator password updated.", "ok")
            elif action in {"add", "reset", "remove"}:
                username = request.form.get("username", "")
                if action == "add" and not settings.valid_username(username):
                    raise ValueError("Use letters, numbers, spaces or the characters _ @ . + - for the username.")
                password = settings.password_hash(new_password()) if action != "remove" else None
                with settings.edit() as state:
                    if username == state["admin"]["username"]:
                        raise ValueError("Use Edit on the administrator account to change its password.")
                    users = state["users"]
                    if action == "add" and username in users:
                        raise ValueError("That sync username already exists.")
                    if action != "add" and username not in users:
                        raise ValueError("That sync username no longer exists.")
                    if action == "remove":
                        del users[username]
                    else:
                        users[username] = password
                flash("Sync users updated. The sync service applies the change in a few seconds.", "ok")
            else:
                abort(400)
        except ValueError as exc:
            flash(str(exc), "error")
            show_add = "1" if action == "add" else None
        return redirect(url_for("dashboard", tab=tab, add=show_add), code=303)
