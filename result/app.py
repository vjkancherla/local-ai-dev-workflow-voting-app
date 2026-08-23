"""Result service: query Postgres and render counts + percentages."""

import json
import os
import time

import psycopg2
from flask import Flask, render_template
from psycopg2 import errors

app = Flask(__name__)

OPTIONS = json.loads(os.environ.get("OPTIONS", '["Cats", "Dogs"]'))

# Retry settings for transient Postgres connection failures under load
_DB_RETRIES = int(os.environ.get("DB_RETRIES", "3"))
_DB_RETRY_DELAY = float(os.environ.get("DB_RETRY_DELAY", "0.1"))


def _connect():
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )


def _connect_with_retry():
    """Connect to Postgres with retry to handle transient failures under load."""
    last_err = None
    for attempt in range(_DB_RETRIES):
        try:
            return _connect()
        except (psycopg2.OperationalError, psycopg2.InterfaceError) as e:
            last_err = e
            if attempt < _DB_RETRIES - 1:
                time.sleep(_DB_RETRY_DELAY)
    raise last_err


def _counts():
    conn = _connect_with_retry()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT choice, COUNT(*) FROM votes GROUP BY choice")
            return dict(cur.fetchall())
    finally:
        conn.close()


@app.route("/")
def index():
    try:
        counts = _counts()
    except errors.UndefinedTable:
        # Table not created yet — the worker's initContainer owns the DDL.
        # Treat as empty rather than erroring while the cluster warms up.
        counts = {}

    total = sum(counts.values())
    results = []
    for option in OPTIONS:
        count = counts.get(option, 0)
        percent = (count / total * 100.0) if total else 0.0
        results.append({"option": option, "count": count, "percent": round(percent, 1)})
    return render_template("result.html", results=results, total=total)


@app.route("/healthz")
def healthz():
    try:
        conn = _connect_with_retry()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        finally:
            conn.close()
        return "OK", 200
    except psycopg2.Error:
        return "Unhealthy", 503
