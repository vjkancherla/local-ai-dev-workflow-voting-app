"""Worker: drain votes from Redis (FIFO) and upsert into Postgres.

No HTTP server — Kubernetes liveness/readiness probes run
`python app.py --healthcheck`, which reports Redis + Postgres status.

Known limitation (documented, accepted for the single-node MVP): BLPOP is
destructive. If the process is killed between a successful BLPOP and the
Postgres COMMIT, that single in-flight vote is lost. Production would use
BLMOVE or Redis Streams to close this window.
"""

import json
import logging
import os
import signal
import sys
import time

import psycopg2
import redis

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("worker")

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")

UPSERT = """
INSERT INTO votes (voter_id, choice, updated_at)
VALUES (%s, %s, to_timestamp(%s))
ON CONFLICT (voter_id)
DO UPDATE SET
    choice = EXCLUDED.choice,
    updated_at = EXCLUDED.updated_at
WHERE votes.updated_at < EXCLUDED.updated_at
"""

_shutdown = False


def _connect_db():
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )


def healthcheck() -> int:
    """Return 0 if both Redis and Postgres are reachable, else 1."""
    try:
        redis.from_url(REDIS_URL, decode_responses=True).ping()
    except redis.RedisError as exc:
        print(f"redis unreachable: {exc}", file=sys.stderr)
        return 1
    try:
        conn = _connect_db()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        finally:
            conn.close()
    except psycopg2.Error as exc:
        print(f"postgres unreachable: {exc}", file=sys.stderr)
        return 1
    return 0


def _handle_signal(signum, _frame):
    global _shutdown
    log.info("received signal %s, shutting down", signum)
    _shutdown = True


def main() -> None:
    r = redis.from_url(REDIS_URL, decode_responses=True)
    conn = None

    while not _shutdown:
        if conn is None:
            try:
                conn = _connect_db()
            except psycopg2.Error:
                log.warning("postgres unavailable; retrying in 2s", exc_info=True)
                time.sleep(2)
                continue

        try:
            item = r.blpop("votes", timeout=5)
            if item is None:
                continue
            _, raw = item
            vote = json.loads(raw)
            voter_id = vote["voter_id"]
            choice = vote["choice"]
            timestamp = float(vote.get("timestamp", time.time()))

            try:
                with conn.cursor() as cur:
                    cur.execute(UPSERT, (voter_id, choice, timestamp))
                conn.commit()
            except psycopg2.Error:
                log.error("postgres error; dropping connection", exc_info=True)
                try:
                    conn.close()
                except psycopg2.Error:
                    pass
                conn = None
        except redis.RedisError:
            log.warning("redis error; reconnecting in 1s", exc_info=True)
            time.sleep(1)
            r = redis.from_url(REDIS_URL, decode_responses=True)
        except (json.JSONDecodeError, KeyError, ValueError):
            log.warning("malformed vote message: %r", raw, exc_info=True)

    if conn is not None:
        conn.close()
    log.info("shutdown complete")


if __name__ == "__main__":
    if "--healthcheck" in sys.argv:
        sys.exit(healthcheck())
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    main()
