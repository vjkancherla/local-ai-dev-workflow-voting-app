# System Patterns

## Architecture
`vote` (Flask/gunicorn) → Redis `votes` list (RPUSH) → `worker` (BLPOP drain, idempotent upsert) → Postgres → `result` (Flask/gunicorn polls Postgres). Redis and Postgres run as Kubernetes StatefulSets/Deployments in the same k3d cluster; vote and result are fronted by an nginx Ingress.

## Patterns
- One-vote-per-browser via a signed Flask session cookie (`voter_id` UUID).
- Idempotent upsert: `ON CONFLICT (voter_id) DO UPDATE WHERE updated_at < EXCLUDED.updated_at`.
- Zero-CPU queue drain: worker blocks on `BLPOP`; exec probes run `python app.py --healthcheck`.
- Single kustomize overlay for all workloads; secrets come from a Kubernetes Secret, not chart values.

## Decisions
- Helm → Kustomize (human override); synthesis docs still reference Helm (stale).
- Traefik → nginx ingress + nip.io (partial — ingress YAML not fully updated).
- Decision log format: `docs/decisions/0000-template.md`.
