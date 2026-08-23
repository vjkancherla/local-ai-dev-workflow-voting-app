# Voting App — Requirements

## Topology
vote (Flask) → redis (queue) → worker (Python) → postgres → result (Flask)

## Functional
| ID | Requirement | Check |
|---|---|---|
| R1 | Vote page offers exactly two options | GET / returns 200 containing both option labels |
| R2 | Casting a vote enqueues it | POST /vote returns 200; redis list length increments |
| R3 | One vote per browser; re-voting replaces the prior vote | Two POSTs, same session cookie → tally total unchanged |
| R4 | Worker drains the queue into postgres, idempotent per voter | Replay the same queue entry twice → one row |
| R5 | Result page shows counts and percentages for both options | GET / on result returns 200 with both counts |
| R6 | A new vote appears in results within 5s | POST vote, poll result, assert within 5s |

## Data
| ID | Requirement | Check |
|---|---|---|
| R7 | Schema is votes(voter_id PK, choice, updated_at) | \d votes matches |
| R8 | Queued-but-unprocessed votes survive a worker restart | Stop worker, vote, start worker, vote appears |
| R9 | Tally survives a postgres pod restart | Delete pod, wait ready, tally unchanged |

## Platform
| ID | Requirement | Check |
|---|---|---|
| R10 | All five workloads have liveness and readiness probes | No workload lacks either in rendered manifests |
| R11 | All five have resource requests and limits | Same |
| R12 | Deployed as one Helm chart; replicas, image tags and resources are values | helm template renders with overrides applied |
| R13 | vote and result reachable via Traefik Ingress | curl through the k3d loadbalancer port returns 200 for both |
| R14 | No NodePort services | kubectl get svc shows none |
| R15 | Images built locally for arm64 from a local registry | crictl/docker inspect shows arm64; image refs point at the k3d registry |
| R16 | Each service exposes /healthz reporting dependency status | GET /healthz returns 200 when deps up, non-200 when down |
| R17 | Postgres credentials come from a Kubernetes Secret, not chart values | grep the chart for a literal password → no match |

## Out of scope
Authentication. TLS. Multi-tenancy. Horizontal autoscaling. Monitoring stack.
Real-time push (polling is acceptable). Migrations framework (single DDL at startup is fine).

## Definition of done
Every check above passes and is recorded in .workflow/verify.md.