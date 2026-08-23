"""Vote service: render two options and enqueue votes into Redis (FIFO)."""

import json
import os
import time
import uuid

import redis
from flask import Flask, redirect, render_template, request, session, url_for

app = Flask(__name__)
app.secret_key = os.environ["SECRET_KEY"]
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
OPTIONS = json.loads(os.environ.get("OPTIONS", '["Cats", "Dogs"]'))


def _redis():
    return redis.from_url(REDIS_URL, decode_responses=True)


def _voter_id():
    if "voter_id" not in session:
        session["voter_id"] = uuid.uuid4().hex
    return session["voter_id"]


@app.route("/")
def index():
    _voter_id()
    return render_template("index.html", options=OPTIONS)


@app.route("/vote", methods=["POST"])
def vote():
    choice = request.form.get("choice")
    if choice not in OPTIONS:
        return "invalid choice", 400
    message = {
        "voter_id": _voter_id(),
        "choice": choice,
        "timestamp": time.time(),
    }
    # RPUSH (not LPUSH): paired with the worker's BLPOP this yields FIFO order,
    # so a voter's re-vote is processed in the order it was cast.
    _redis().rpush("votes", json.dumps(message))
    return redirect(url_for("index"))


@app.route("/healthz")
def healthz():
    try:
        _redis().ping()
        return "OK", 200
    except redis.RedisError:
        return "Unhealthy", 503
