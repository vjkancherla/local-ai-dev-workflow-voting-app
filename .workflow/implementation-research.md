# Implementation Research Report - Voting App on k3d/arm64

> Lens: Implementation Researcher - what actually works in practice.
> Status: Complete. All 7 research areas covered. Aug 2026.

---

## 1. Dockerfile Architecture per Service

### Shared multi-stage pattern (all 3 services)

Base: python:3.12-slim (arm64 multi-arch native). Multi-stage: builder stage (pip wheel into /wheels), runtime stage (copy + install + rm wheels). Non-root user UID 10001. ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1. EXPOSE 80.

### Vote service - vote/

- requirements.txt: Flask==3.1.*, gunicorn==23.*, redis==5.*
- CMD: ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "2", "--timeout", "30", "app:app"]
- Why gunicorn: SIGTERM graceful shutdown, drains requests on pod termination. 2 workers matches ~200m CPU limit.

### Worker service - worker/

- requirements.txt: Flask==3.1.*, gunicorn==23.*, redis==5.*, psycopg2-binary==2.9.*
- CMD: ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "1", "--threads", "2", "--timeout", "30", "app:app"]
- Architecture: Two threads - main thread runs vote-processing loop, Flask daemon thread serves /healthz. Workers=1 + threads=2: One thread for requests, one for bg loop.
- CRITICAL - psycopg2-binary on arm64: GitHub issue psycopg/psycopg2#1125 RESOLVED, aarch64 wheels merged via #1130 and psycopg2-wheels#14. Start with psycopg2-binary==2.9.12. If pip fails to find arm64 wheel, fallback to source build: apt-get install build-essential libpq-dev && pip install psycopg2 && apt-get purge build-essential.

### Result service - result/

- requirements.txt: Flask==3.1.*, gunicorn==23.*, psycopg2-binary==2.9.*
- CMD: Same as vote.

### Version pinning

| Package | Version | Rationale |
|---------|---------|-----------|
| python | 3.12-slim | arm64 multi-arch, ~150MB after multi-stage |
| Flask | 3.1.* | Python 3.12 compatible |
| gunicorn | 23.* | SIGTERM graceful shutdown |
| redis-py | 5.* | from_url(), retry support |
| psycopg2-binary | 2.9.* | arm64 wheels since 2.9.x |
| redis image | 7-alpine | ~30MB, arm64 |
| postgres image | 16-alpine | ~150MB, arm64 |


---

## 2. Helm Chart Implementation Patterns

### 2.1 Postgres Secret (R17)

Pattern: lookup + randAlphaNum + helm.sh/resource-policy: keep.

Template logic:
  - lookup "v1" "Secret" to check if Secret already exists
  - If exists: reuse POSTGRES_PASSWORD from data (preserves password across upgrades)
  - If not: randAlphaNum 32 b64enc as new password
  - Annotation "helm.sh/resource-policy": keep prevents helm uninstall deletion
  - No literal password in values.yaml - satisfies R17
  - For helm template dry-runs (no cluster): lookup returns nil, else branch generates random - acceptable for inspection

Rejected alternative: pre-install hook Job. Hooks do NOT fire on upgrade without pre-upgrade annotation. Hook-created resources get deleted on completion. The lookup pattern works for both install and upgrade.

Secret name: {{ .Release.Name }}-postgres
Keys: POSTGRES_USER (value: "postgres"), POSTGRES_PASSWORD (generated)
Referenced by all deployments via secretKeyRef.

### 2.2 Traefik Ingress (R13)

k3d ships Traefik v2+ bundled. Use STANDARD networking.k8s.io/v1 Ingress, NOT the Traefik CRD (IngressRoute).

Key fields:
  - apiVersion: networking.k8s.io/v1
  - ingressClassName: traefik (NOT nginx - k3d uses Traefik)
  - Annotation: traefik.ingress.kubernetes.io/router.entrypoints: web
  - Two rules: vote.local -> <release>-vote:80, result.local -> <release>-result:80
  - pathType: Prefix, path: /

For local testing, add to /etc/hosts: 127.0.0.1 vote.local result.local
Access: http://vote.local:8080/ (host port 8080 maps to loadbalancer port 80)

### 2.3 DDL Execution (R7)

Pattern: initContainer on BOTH worker and result deployments. NO Helm hook Job needed.

initContainer spec:
  - Image: postgres:16-alpine (reuses postgres image for psql binary)
  - Command: ["psql"]
  - Args: -h <release>-postgres -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c "CREATE TABLE IF NOT EXISTS votes (...)"
  - Env: POSTGRES_USER, PGPASSWORD from Secret; POSTGRES_DB from values
  - SQL: CREATE TABLE IF NOT EXISTS votes (voter_id VARCHAR(255) PRIMARY KEY, choice VARCHAR(255) NOT NULL, updated_at TIMESTAMP NOT NULL DEFAULT NOW())

Why initContainer > startup script in app code:
  - Runs to completion BEFORE main container starts - guarantees schema
  - Uses postgres image's psql binary (no extra tools in app image)
  - IF NOT EXISTS = idempotent across upgrades/restarts
  - Both worker+result run it per design spec
  - No race conditions vs startup scripts in multiple replicas

### 2.4 values.yaml Structure

All configurable per R12: replicaCount (global default 1), image.repository/tag per service, resources per service, vote.options (exactly 2), postgres.storageSize (default 1Gi), postgres.database (default "voting"), secretKey (Flask SECRET_KEY, generated if empty).

Redis/postgres use official Docker Hub images. Application images reference k3d-voting-app-registry.localhost:5000/...

### 2.5 Service Types (R14)

ALL services use type: ClusterIP. No NodePort anywhere. External access only through Ingress. redis-service and postgres-service are cluster-internal only (no ingress rules).

### 2.6 Probes (R10)

vote/worker/result: HTTP GET /healthz:80, liveness period 10s/initialDelay 5s, readiness period 5s/initialDelay 3s
redis: tcpSocket port 6379, liveness period 10s, readiness period 5s
postgres: exec pg_isready -U postgres, liveness period 10s/initialDelay 30s, readiness period 5s/initialDelay 30s
All 5 workloads have both liveness AND readiness probes - satisfies R10.

### 2.7 Template File Inventory

helm/voting-app/
  Chart.yaml
  values.yaml
  templates/
    _helpers.tpl
    postgres-secret.yaml
    postgres-statefulset.yaml
    postgres-service.yaml
    redis-deployment.yaml
    redis-service.yaml
    vote-deployment.yaml
    vote-service.yaml
    worker-deployment.yaml
    result-deployment.yaml
    result-service.yaml
    ingress.yaml

---
## 3. k3d Local Registry Workflow

### 3.1 Create Cluster with Registry

```
k3d cluster create voting-app \
  --registry-create voting-app-registry.localhost:5000 \
  -p "8080:80@loadbalancer" \
  --agents 1
```

What this creates:
  - Docker containers: 1 k3s server + 1 agent + 1 loadbalancer (nginx)
  - Registry container: k3d-voting-app-registry.localhost (port 5000 internal -> host localhost:5000)
  - Port mapping: loadbalancer:80 -> host:8080 (for HTTP ingress)
  - Traefik ingress controller: pre-installed (bundled with K3s)
  - k3d auto-generates /etc/rancher/k3s/registries.yaml inside cluster for containerd pull

macOS GOTCHA: Port 5000 may be claimed by AirPlay Receiver. Check: lsof -i :5000
If occupied, use port 5001 throughout: --registry-create voting-app-registry.localhost:5001

### 3.2 Build and Push Images

```
docker build --platform linux/arm64 -t localhost:5000/vote:latest   -f vote/Dockerfile .
docker build --platform linux/arm64 -t localhost:5000/worker:latest -f worker/Dockerfile .
docker build --platform linux/arm64 -t localhost:5000/result:latest -f result/Dockerfile .

docker push localhost:5000/vote:latest
docker push localhost:5000/worker:latest
docker push localhost:5000/result:latest
```

KEY NAMING DETAIL:
  - Push from host: localhost:5000 (host-mapped port)
  - Pull within cluster: k3d-voting-app-registry.localhost:5000 (container DNS name + internal port)
  - Containerd inside K3s resolves *.localhost names via k3d's DNS setup
  - The repository path (e.g., /vote) is the same in both contexts

ALTERNATIVE (quick debug only): k3d image import vote:latest -c voting-app --mode direct
But this bypasses the local registry - not suitable for R15 compliance.

### 3.3 Verify Registry Connectivity

```
# List registry contents
curl -s http://localhost:5000/v2/_catalog
# Expected: {"repositories":["result","vote","worker"]}

# Check specific image tags
curl -s http://localhost:5000/v2/vote/tags/list
# Expected: {"name":"vote","tags":["latest"]}

# Test pull from within cluster
kubectl run reg-test --image=k3d-voting-app-registry.localhost:5000/vote:latest \
  --restart=Never --command -- sleep 5
kubectl get pod reg-test  # Should not show ImagePullBackOff/ErrImagePull
kubectl delete pod reg-test

# Verify arm64 architecture
docker inspect localhost:5000/vote:latest | jq '.[0].Architecture'
# Expected: "arm64"
```

### 3.4 Deploy Helm Chart

```
helm install voting-app ./helm/voting-app
kubectl get pods -w  # Wait for all 5 workloads Running
curl http://vote.local:8080/  # Should return HTML with voting form
```

### 3.5 Shutdown

```
helm uninstall voting-app
k3d cluster delete voting-app
# Registry container auto-removed with cluster
```

---

## 4. Flask Production Patterns

### 4.1 Vote Service - vote/app.py

Session Config:
  - SECRET_KEY from env var (Helm generates, injects via Secret env ref)
  - SESSION_COOKIE_HTTPONLY = True (prevents JS cookie access)
  - SESSION_COOKIE_SAMESITE = "Lax" (standard CSRF protection)

Endpoint / (GET):
  - Render index.html template with options from env var OPTIONS (JSON list)
  - If no voter_id cookie: generate uuid.uuid4().hex (32-char), set as BOTH Flask session AND plain cookie
  - Plain cookie needed because worker reads voter_id from the vote message, not from Flask session

Endpoint /vote (POST):
  - Read choice from request.form["choice"], voter_id from request.cookies.get("voter_id")
  - Validate choice is in OPTIONS list (from env) -> 400 if not
  - Return 400 if voter_id missing
  - r = redis.from_url(REDIS_URL), r.lpush("votes", json.dumps({"voter_id": voter_id, "choice": choice}))
  - Redirect or re-render template with voted=True flag
  - Does NOT check Redis for duplicate - worker handles idempotency per design R4

Endpoint /healthz (GET):
  - Try: redis.from_url(REDIS_URL, socket_connect_timeout=2).ping()
  - Success: return "OK", 200
  - Exception (redis.RedisError): return "Unhealthy", 503

### 4.2 Result Service - result/app.py

Endpoint / (GET):
  - Connect Postgres: conn = psycopg2.connect(POSTGRES_URL)
  - Query: SELECT choice, COUNT(*) as count FROM votes GROUP BY choice ORDER BY choice
  - Calculate total, percentages per option, handle zero-total gracefully (no division by zero)
  - Render HTML table: Option | Count | Percentage
  - Auto-refresh: <meta http-equiv="refresh" content="2"> (or JS setInterval polling)
  - 2s refresh satisfies R6 (5s latency window) without WebSocket/SSE complexity

Endpoint /healthz (GET):
  - Try: conn = psycopg2.connect(POSTGRES_URL), cursor.execute("SELECT 1"), cursor.fetchone()
  - Success: "OK", 200
  - Exception: "Unhealthy", 503

### 4.3 Worker Service - worker/app.py

Dual-purpose single-process Flask app:
  - /healthz endpoint: checks Redis PING AND Postgres SELECT 1 - both must succeed
  - Background daemon thread running main() processing loop

main() loop logic (runs in threading.Thread with daemon=True):
  1. r = redis.from_url(REDIS_URL, decode_responses=True)
  2. conn = psycopg2.connect(POSTGRES_URL)
  3. global shutdown = False
  4. While not shutdown:
     a. vote_json = r.lpop("votes")  # LPOP per design spec, not BLPOP
     b. If None: time.sleep(0.1); continue  # per design: 0.1s sleep to avoid busy-spin
     c. vote = json.loads(vote_json)
     d. Upsert with parameterized query:
        INSERT INTO votes (voter_id, choice, updated_at) VALUES (%s, %s, NOW())
        ON CONFLICT (voter_id) DO UPDATE SET choice = EXCLUDED.choice, updated_at = NOW()
     e. conn.commit()
  5. On redis.RedisError: log.warning, time.sleep(1), reconnect r
  6. On psycopg2.Error: conn.rollback(), log.error, time.sleep(1), reconnect conn
  7. On SIGTERM/SIGINT (signal handler): shutdown = True, conn.close(), log.info("shutdown complete")

Connection Strategy:
  - Redis: Single redis.from_url() with socket_connect_timeout=2. redis-py internally handles reconnect. No ConnectionPool needed for single-threaded worker.
  - Postgres: Single psycopg2.connect(), no connection pool (single threaded). On psycopg2.Error: rollback + reconnect fresh. autocommit=False (explicit conn.commit()).

IMPORTANT: LPOP vs BLPOP tradeoff - Design specifies LPOP with 0.1s sleep. In production, BLPOP("votes", timeout=1) would be better (event-driven, no busy-wait). But LPOP + sleep is simpler and satisfies all requirements since latency budget is 5s (R6). The 0.1s polling adds at most 100ms to worst-case drain time.

---

## 5. Verification Strategy - 17 Requirements -> Concrete Commands

### R1: Vote page offers exactly two options
```
RESP=$(curl -s http://vote.local:8080/)
echo "$RESP" | grep -o 'value="' | wc -l | xargs -I{} [ {} -eq 2 ] && echo "PASS R1" || echo "FAIL R1"
```
EXPECT: Exactly 2 value= attributes (two radio/option inputs). Verify HTML contains both label strings from values.yaml.

### R2: Casting a vote enqueues it
```
BEFORE=$(kubectl exec deploy/redis -- redis-cli LLEN votes)
curl -s -X POST http://vote.local:8080/vote -d "choice=Cats" -c /tmp/cookies-v.txt
sleep 1
AFTER=$(kubectl exec deploy/redis -- redis-cli LLEN votes)
[ $AFTER -gt $BEFORE ] && echo "PASS R2: $BEFORE -> $AFTER" || echo "FAIL R2"
```
EXPECT: AFTER > BEFORE (Redis list length increased by >=1)

### R3: One vote per browser; re-vote replaces prior vote
```
curl -s http://vote.local:8080/ -c /tmp/cookies-r3.txt > /dev/null
curl -s -X POST http://vote.local:8080/vote -d "choice=Cats" -b /tmp/cookies-r3.txt
sleep 3
TOTAL1=$(kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -t -c "SELECT COUNT(*) FROM votes" | tr -d '[:space:]')
curl -s -X POST http://vote.local:8080/vote -d "choice=Dogs" -b /tmp/cookies-r3.txt
sleep 3
TOTAL2=$(kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -t -c "SELECT COUNT(*) FROM votes" | tr -d '[:space:]')
[ "$TOTAL1" == "$TOTAL2" ] && echo "PASS R3: total unchanged at $TOTAL1" || echo "FAIL R3: $TOTAL1 -> $TOTAL2"
```
EXPECT: TOTAL1 == TOTAL2 (upsert, not insert - row count unchanged)

### R4: Worker idempotent per voter
```
kubectl exec deploy/redis -- redis-cli LPUSH votes '{"voter_id":"test-r4","choice":"Cats"}'
kubectl exec deploy/redis -- redis-cli LPUSH votes '{"voter_id":"test-r4","choice":"Cats"}'
sleep 3
COUNT=$(kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -t -c "SELECT COUNT(*) FROM votes WHERE voter_id='test-r4'" | tr -d '[:space:]')
[ "$COUNT" == "1" ] && echo "PASS R4: one row for test-r4" || echo "FAIL R4: got $COUNT rows"
```
EXPECT: count = 1 (ON CONFLICT upsert collapsed duplicates)

### R5: Result page shows counts and percentages
```
RESULT=$(curl -s http://result.local:8080/)
echo "$RESULT" | grep -E '[0-9]+%' && echo "PASS R5: percentages found" || echo "FAIL R5"
```
EXPECT: HTML contains both option labels, numeric counts, and percentage values.

### R6: New vote appears in results within 5 seconds
```
curl -s -X POST http://vote.local:8080/vote -d "choice=Cats" -c /tmp/cookies-r6.txt
START=$(date +%s)
for i in $(seq 1 15); do
  if curl -s http://result.local:8080/ 2>/dev/null | grep -q "Cats"; then
    ELAPSED=$(($(date +%s) - START))
    echo "PASS R6: vote appeared in ${ELAPSED}s (limit: 5s)"
    break
  fi
  sleep 0.5
done
[ $i -ge 15 ] && echo "FAIL R6: vote did not appear within 7.5s"
```
EXPECT: grep matches within 10 iterations (~5 seconds). The auto-refresh meta tag also contributes.

### R7: Schema is votes(voter_id PK, choice, updated_at)
```
kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -c "\d votes"
```
EXPECT output: voter_id | character varying(255) | not null | (PK)
              choice   | character varying(255) | not null |
              updated_at | timestamp without time zone | not null | default now()

### R8: Queued votes survive worker restart
```
kubectl scale deploy/worker --replicas=0 && sleep 3
curl -s -X POST http://vote.local:8080/vote -d "choice=Cats" -c /tmp/cookies-r8.txt
QUEUED=$(kubectl exec deploy/redis -- redis-cli LLEN votes | tr -d '[:space:]')
echo "Votes in queue during worker outage: $QUEUED"
[ $QUEUED -ge 1 ] || echo "FAIL R8: no vote in queue"
kubectl scale deploy/worker --replicas=1 && sleep 5
kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -c "SELECT * FROM votes ORDER BY updated_at DESC LIMIT 1;"
```
EXPECT: After worker restart, the queued vote appears in Postgres. Redis list length goes to 0 after drain.

### R9: Tally survives postgres pod restart
```
# Seed some votes first (if none exist)
BEFORE=$(kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -t -c "SELECT COUNT(*) FROM votes" | tr -d '[:space:]')
echo "Tally before pod restart: $BEFORE"
kubectl delete pod postgres-0
kubectl wait --for=condition=Ready pod/postgres-0 --timeout=120s
sleep 5
AFTER=$(kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -t -c "SELECT COUNT(*) FROM votes" | tr -d '[:space:]')
[ "$BEFORE" == "$AFTER" ] && echo "PASS R9: tally preserved ($BEFORE)" || echo "FAIL R9: $BEFORE -> $AFTER"
```
EXPECT: BEFORE == AFTER. PVC re-attached by StatefulSet, data preserved.

### R10: All 5 workloads have liveness AND readiness probes
```
kubectl get deploy -o json | jq '.items[] | {name: .metadata.name, liveness: .spec.template.spec.containers[0].livenessProbe != null, readiness: .spec.template.spec.containers[0].readinessProbe != null}'
kubectl get statefulset -o json | jq '.items[] | {name: .metadata.name, liveness: .spec.template.spec.containers[0].livenessProbe != null, readiness: .spec.template.spec.containers[0].readinessProbe != null}'
```
EXPECT: All 5 return liveness=true AND readiness=true. No workload lacks either probe.
ALTERNATIVE: helm template ./helm/voting-app | grep -c "livenessProbe" -> 5, and "readinessProbe" -> 5.

### R11: All 5 workloads have resource requests AND limits
```
kubectl get deploy,statefulset -o json | jq '[.items[] | .spec.template.spec.containers[] | {name, requests: .resources.requests, limits: .resources.limits}]'
echo "---"
helm template ./helm/voting-app | grep -A2 "resources:" | grep -c "requests:"  # -> 5
helm template ./helm/voting-app | grep -A3 "resources:" | grep -c "limits:"    # -> 5
```
EXPECT: All 5 containers have both requests and limits defined for CPU and memory.

### R12: One Helm chart, configurable values
```
helm template ./helm/voting-app --set vote.options='["Pizza","Burgers"]' --set vote.image.tag=v2 | grep "Pizza"
helm template ./helm/voting-app --set vote.image.tag=v2 | grep "v2"
helm template ./helm/voting-app --set worker.resources.requests.cpu=100m | grep "100m"
```
EXPECT: Overridden values appear in rendered output. Template renders without error.
VERIFY: helm lint ./helm/voting-app returns no errors.

### R13: vote and result reachable via Traefik Ingress
```
curl -s -o /dev/null -w "%{http_code}" http://vote.local:8080/
# Expected: 200
curl -s -o /dev/null -w "%{http_code}" http://result.local:8080/
# Expected: 200
kubectl get ingress -o yaml | grep -A5 "host:"
# Shows vote.local and result.local rules
```
EXPECT: Both return HTTP 200. Ingress resource shows correct rules.

### R14: No NodePort services
```
kubectl get svc -o json | jq '[.items[] | select(.spec.type == "NodePort")] | length'
```
EXPECT: 0 (no NodePort services)

### R15: Images built locally for arm64 from local registry
```
# Check image architecture
docker inspect localhost:5000/vote:latest | jq '.[0].Architecture'
# Expected: "arm64"

# Check deployment images reference local registry
kubectl get deploy -o json | jq '.items[].spec.template.spec.containers[].image'
# Expected: all contain "k3d-voting-app-registry.localhost:5000"
```
EXPECT: arm64 architecture on all 3 app images. Deployment image fields point at k3d local registry.

### R16: Each service exposes /healthz
```
# Vote healthz
curl -s -o /dev/null -w "%{http_code}" http://vote.local:8080/healthz
# Expected: 200

# Result healthz
curl -s -o /dev/null -w "%{http_code}" http://result.local:8080/healthz
# Expected: 200

# Worker healthz (via port-forward or exec)
kubectl exec deploy/worker -- curl -s -o /dev/null -w "%{http_code}" http://localhost:80/healthz
# Expected: 200

# Redis healthz (tcpSocket probe - verify in pod spec)
kubectl get deploy redis -o yaml | grep -A3 "livenessProbe" | grep "tcpSocket"

# Postgres healthz (exec probe)
kubectl get statefulset postgres -o yaml | grep -A5 "livenessProbe" | grep "pg_isready"
```
EXPECT: All return 200. Non-200 when dependencies down - test by scaling down redis and checking vote /healthz -> should return non-200.

### R17: Postgres credentials from Secret, not chart values
```
# Verify no literal password in chart
grep -r "password" helm/voting-app/values.yaml || echo "PASS R17: no literal password in values.yaml"
grep -r "POSTGRES_PASSWORD" helm/voting-app/values.yaml || echo "PASS R17: no PASSWORD ref in values.yaml"

# Verify Secret exists and is used
kubectl get secret -o yaml | grep "POSTGRES_PASSWORD"
kubectl get deploy worker -o yaml | grep -A5 "secretKeyRef" | grep "POSTGRES_PASSWORD"
```
EXPECT: No literal password found in values.yaml. Secret exists with POSTGRES_PASSWORD. Deployments reference via secretKeyRef.

---

## 6. Verification Script Outline (Full)

R1-R17 combined bash verification script (verify.sh in project root):
  1. R1: curl vote page, count option values
  2. R2: Record redis LLEN, POST vote, verify increment
  3. R3: Vote twice with same cookie, verify row count unchanged
  4. R4: Manual LPUSH duplicate, verify upsert
  5. R5: curl result page, grep for percentages
  6. R6: POST vote, poll result with timing (timeout 5s)
  7. R7: psql \d votes, verify schema
  8. R8: Stop worker, vote, start worker, verify drain
  9. R9: Record tally, delete pod, wait ready, verify tally
  10. R10: jq check liveness+readiness on all 5
  11. R11: jq check requests+limits on all 5
  12. R12: helm template with overrides + helm lint
  13. R13: curl both ingress hosts -> 200
  14. R14: count NodePort services -> 0
  15. R15: docker inspect arm64 + check image refs
  16. R16: curl /healthz on all services -> 200
  17. R17: grep values.yaml for password (should fail) + verify Secret exists

Results logged to .workflow/verify.md per CODING-STANDARDS.md.

---

## 7. Implementation Map - Task Breakdown (File + Purpose + Dependencies + Complexity)

### Phase 1: Foundation (Project Scaffolding)

1. .gitignore - Python/Docker/k8s ignore patterns - none - S
2. vote/Dockerfile - Multi-stage arm64, Flask+gunicorn+redis - none - S
3. vote/requirements.txt - Flask==3.1.*, gunicorn==23.*, redis==5.* - none - S
4. vote/app.py - Flask app: /, /vote, /healthz endpoints - none - M
5. vote/templates/index.html - Voting form with two option buttons - vote/app.py - S
6. result/Dockerfile - Multi-stage arm64, Flask+gunicorn+psycopg2 - none - S
7. result/requirements.txt - Flask==3.1.*, gunicorn==23.*, psycopg2-binary==2.9.* - none - S
8. result/app.py - Flask app: /, /healthz endpoints, Postgres queries - none - M
9. result/templates/result.html - Result display with auto-refresh - result/app.py - S
10. worker/Dockerfile - Multi-stage arm64, Flask+gunicorn+redis+psycopg2 - none - S
11. worker/requirements.txt - Flask+gunicorn+redis+psycopg2-binary - none - S
12. worker/app.py - Flask+threading worker, /healthz, Redis+Postgres logic - none - M

### Phase 2: Helm Chart

13. helm/voting-app/Chart.yaml - Chart metadata (apiVersion v2) - none - S
14. helm/voting-app/values.yaml - All configurable parameters (images, resources, options) - none - M
15. helm/voting-app/templates/_helpers.tpl - Label/naming helpers - Chart.yaml - S
16. helm/voting-app/templates/postgres-secret.yaml - lookup+randAlphaNum Secret (R17) - _helpers.tpl - M
17. helm/voting-app/templates/postgres-statefulset.yaml - StatefulSet + PVC + env from Secret (R7,R9) - postgres-secret.yaml - M
18. helm/voting-app/templates/postgres-service.yaml - ClusterIP (R14) - none - S
19. helm/voting-app/templates/redis-deployment.yaml - Deployment with AOF config (R8) - none - S
20. helm/voting-app/templates/redis-service.yaml - ClusterIP (R14) - none - S
21. helm/voting-app/templates/vote-deployment.yaml - Deployment + initContainer + probes (R10,R11) - vote/Dockerfile, postgres-secret.yaml - M
22. helm/voting-app/templates/vote-service.yaml - ClusterIP (R14) - none - S
23. helm/voting-app/templates/worker-deployment.yaml - Deployment + initContainer DDL + probes (R7,R10,R11) - worker/Dockerfile, postgres-secret.yaml - M
24. helm/voting-app/templates/result-deployment.yaml - Deployment + initContainer DDL + probes (R7,R10,R11) - result/Dockerfile, postgres-secret.yaml - M
25. helm/voting-app/templates/result-service.yaml - ClusterIP (R14) - none - S
26. helm/voting-app/templates/ingress.yaml - Traefik Ingress (R13) - vote-service.yaml, result-service.yaml - S

### Phase 3: Build & Deploy Scripts

27. Makefile (optional) or scripts/build.sh - Build all 3 docker images + push - Dockerfiles - S
28. scripts/deploy.sh - k3d cluster create, helm install, wait for ready - Helm chart - S
29. scripts/verify.sh - Full R1-R17 verification script - all Phase 1+2 - L
30. .workflow/verify.md - Verification results output (per CODING-STANDARDS.md) - scripts/verify.sh - S

### Phase 4: Documentation

31. README.md - Quick start: prerequisites, build, deploy, verify, shutdown - all - M

### Dependency Graph

```
.gitignore, vote/Dockerfile, result/Dockerfile, worker/Dockerfile
  |
  +-> vote/app.py + result/app.py + worker/app.py
  |     |
  |     +-> vote/templates/ + result/templates/
  |
  +-> helm/voting-app/Chart.yaml
        |
        +-> values.yaml
        |     |
        |     +-> _helpers.tpl
        |           |
        |           +-> postgres-secret.yaml
        |           |     |
        |           |     +-> postgres-statefulset.yaml
        |           |     +-> vote-deployment.yaml
        |           |     +-> worker-deployment.yaml
        |           |     +-> result-deployment.yaml
        |           |
        |           +-> postgres-service.yaml
        |           +-> redis-deployment.yaml
        |           +-> redis-service.yaml
        |           +-> vote-service.yaml
        |           +-> result-service.yaml
        |                 |
        |                 +-> ingress.yaml
        |
        +-> scripts/*.sh
        +-> README.md
```

### Complexity Legend:
  S = Simple (1 file, straightforward logic, <30 lines)
  M = Medium (requires integration, templates with conditionals, 30-80 lines)
  L = Large (multi-step script, error handling, 80+ lines)

### File Count Summary:
  - Python applications: 9 files (3 Dockerfiles + 3 requirements.txt + 3 app.py + 2 templates)
  - Helm chart: 14 files (Chart.yaml + values.yaml + 12 templates)
  - Scripts/docs: 4 files (build.sh + deploy.sh + verify.sh + README.md)
  - **Total: 27 files to create**

### Critical Path (earliest time-to-running):
  1. Dockerfiles + app.py files (parallel, ~30 min)
  2. Helm chart templates (mostly parallel after Phase 1, ~45 min)
  3. Build images + push to registry (~5 min)
  4. Deploy + verify (~5 min)
  **Total estimated: ~85 min for MVP**
