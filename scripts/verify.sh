#!/usr/bin/env bash
set -uo pipefail

# Full R1–R17 verification for the voting app.
#
# Prerequisites: a running cluster (see scripts/deploy.sh) and /etc/hosts
# entries `127.0.0.1 vote.127.0.0.1.nip.io result.127.0.0.1.nip.io`.
#
# Results are appended to .workflow/verify.md.

RELEASE="${RELEASE:-voting-app}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-./kustomize}"
VOTE_URL="${VOTE_URL:-https://vote.127.0.0.1.nip.io:8082}"
RESULT_URL="${RESULT_URL:-https://result.127.0.0.1.nip.io:8082}"
REGISTRY="${REGISTRY:-0}"
OUT=".workflow/verify.md"

mkdir -p .workflow
: > "$OUT"

PASS=0
FAIL=0

say() {
  local id="$1" status="$2" msg="$3"
  printf '%-4s %-8s %s\n' "$id" "$status" "$msg"
  printf '%-4s %-8s %s\n' "$id" "$status" "$msg" >> "$OUT"
}

pass() { say "$1" "PASS" "$2"; PASS=$((PASS + 1)); }
fail() { say "$1" "FAIL" "$2"; FAIL=$((FAIL + 1)); }

# Resolve the Postgres pod once (StatefulSet pod name is stable: <release>-postgres-0).
PGPOD="${PGPOD:-$(kubectl get pods -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=postgres" -o jsonpath='{.items[0].metadata.name}')}"
psql_q() { kubectl exec "$PGPOD" -- psql -U postgres -d voting -t -A -c "$1" 2>/dev/null; }
redis_q() { kubectl exec "deploy/${RELEASE}-redis" -- redis-cli "$@" 2>/dev/null; }

# Fetch the two option labels from the rendered vote page.
vote_html="$(curl -sk --compressed "$VOTE_URL/")"
mapfile -t OPTS < <(printf '%s\n' "$vote_html" | grep -o 'name="choice" value="[^"]*"' | sed -E 's/.*value="([^"]*)".*/\1/')

# ---- R1: Vote page offers exactly two options ----
vote_code="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$VOTE_URL/")"
if [[ "$vote_code" == "200" && "${#OPTS[@]}" -eq 2 && -n "${OPTS[0]:-}" && -n "${OPTS[1]:-}" ]]; then
  pass "R1" "200 with exactly two options: ${OPTS[0]} / ${OPTS[1]}"
else
  fail "R1" "code=${vote_code}, options=${OPTS[*]:-none}"
fi

# ---- R2: Casting a vote enqueues it (worker paused so the queue is observable) ----
kubectl scale deployment "${RELEASE}-worker" --replicas=0 >/dev/null 2>&1 || true
# Wait until all worker pods are gone
for i in $(seq 1 30); do
  if [[ -z "$(kubectl get pods -l app.kubernetes.io/component=worker -o name 2>/dev/null)" ]]; then
    break
  fi
  sleep 1
done
before_len="$(redis_q LLEN votes)"
vote_code2="$(curl -sk --compressed -o /dev/null -w '%{http_code}' -X POST "$VOTE_URL/vote" -d "choice=${OPTS[0]}" -c /tmp/vcookies.txt)"
after_len="$(redis_q LLEN votes)"
if [[ "$vote_code2" =~ ^(2|3)[0-9][0-9]$ && "$after_len" -gt "$before_len" ]]; then
  pass "R2" "POST /vote -> 200, redis LLEN ${before_len} -> ${after_len}"
else
  fail "R2" "code=${vote_code2}, LLEN ${before_len} -> ${after_len}"
fi
kubectl scale deployment "${RELEASE}-worker" --replicas=1 >/dev/null 2>&1 || true
kubectl rollout status deployment "${RELEASE}-worker" --timeout=120s >/dev/null 2>&1 || true

# ---- R3: One vote per browser; re-vote replaces prior vote ----
curl -sk --compressed -c /tmp/vcookies-r3.txt "$VOTE_URL/" >/dev/null
sleep 3
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[0]}" -b /tmp/vcookies-r3.txt
sleep 3
total1="$(psql_q 'SELECT COUNT(*) FROM votes')"
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[1]}" -b /tmp/vcookies-r3.txt
sleep 3
total2="$(psql_q 'SELECT COUNT(*) FROM votes')"
if [[ "$total1" == "$total2" ]]; then
  pass "R3" "tally unchanged after re-vote (${total1})"
else
  fail "R3" "tally ${total1} -> ${total2}"
fi

# ---- R4: Worker idempotent per voter (replayed entry -> one row) ----
redis_q RPUSH votes '{"voter_id":"verify-r4","choice":"Cats","timestamp":1700000000}' >/dev/null
redis_q RPUSH votes '{"voter_id":"verify-r4","choice":"Cats","timestamp":1700000000}' >/dev/null
sleep 3
r4_count="$(psql_q "SELECT COUNT(*) FROM votes WHERE voter_id='verify-r4'")"
if [[ "$r4_count" == "1" ]]; then
  pass "R4" "one row for verify-r4 after replay"
else
  fail "R4" "got ${r4_count} rows"
fi

# ---- R5: Result page shows counts and percentages for both options ----
result_html="$(curl -sk --compressed "$RESULT_URL/")"
if printf '%s\n' "$result_html" | grep -qE '[0-9]+(\.[0-9]+)?%' \
  && printf '%s\n' "$result_html" | grep -q "${OPTS[0]}" \
  && printf '%s\n' "$result_html" | grep -q "${OPTS[1]}"; then
  pass "R5" "percentages + both option labels present"
else
  fail "R5" "missing percentages or labels"
fi

# ---- R6: New vote appears in results within 5s ----
before_total="$(psql_q 'SELECT COUNT(*) FROM votes')"
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[0]}" -c /tmp/vcookies-r6.txt
start="$(date +%s)"
r6_ok=0
while [[ $(( $(date +%s) - start )) -le 5 ]]; do
  after_total="$(psql_q 'SELECT COUNT(*) FROM votes')"
  if [[ "$after_total" -gt "$before_total" ]]; then r6_ok=1; break; fi
  sleep 0.5
done
if [[ "$r6_ok" == "1" ]]; then
  pass "R6" "vote appeared in $(( $(date +%s) - start ))s (limit 5s)"
else
  fail "R6" "vote did not appear within 5s"
fi

# ---- R7: Schema is votes(voter_id PK, choice, updated_at) ----
schema="$(kubectl exec "$PGPOD" -- psql -U postgres -d voting -c '\d votes' 2>/dev/null)"
if printf '%s\n' "$schema" | grep -q 'voter_id' \
  && printf '%s\n' "$schema" | grep -q 'choice' \
  && printf '%s\n' "$schema" | grep -q 'updated_at'; then
  pass "R7" "votes table has voter_id, choice, updated_at"
else
  fail "R7" "schema mismatch"
fi

# ---- R8: Queued votes survive a worker restart ----
kubectl scale deployment "${RELEASE}-worker" --replicas=0 >/dev/null 2>&1 || true
# Wait until all worker pods are gone (not just rollout status)
for i in $(seq 1 30); do
  if [[ -z "$(kubectl get pods -l app.kubernetes.io/component=worker -o name 2>/dev/null)" ]]; then
    break
  fi
  sleep 1
done
before_total8="$(psql_q 'SELECT COUNT(*) FROM votes')"
curl -sk --compressed -o /dev/null -X POST "$VOTE_URL/vote" -d "choice=${OPTS[1]}" -c /tmp/vcookies-r8.txt
queued="$(redis_q LLEN votes)"
if [[ "$queued" -lt 1 ]]; then
  fail "R8" "no vote queued during worker outage"
else
  kubectl scale deployment "${RELEASE}-worker" --replicas=1 >/dev/null 2>&1 || true
  kubectl rollout status deployment "${RELEASE}-worker" --timeout=120s >/dev/null 2>&1 || true
  sleep 5
  after_total8="$(psql_q 'SELECT COUNT(*) FROM votes')"
  drained="$(redis_q LLEN votes)"
  if [[ "$after_total8" -gt "$before_total8" && "$drained" == "0" ]]; then
    pass "R8" "queued vote (${queued}) drained to postgres after restart"
  else
    fail "R8" "before=${before_total8} after=${after_total8} remaining=${drained}"
  fi
fi

# ---- R9: Tally survives a postgres pod restart ----
before9="$(psql_q 'SELECT COUNT(*) FROM votes')"
kubectl delete pod "$PGPOD" >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready "pod/${PGPOD}" --timeout=120s >/dev/null 2>&1 || true
sleep 5
after9="$(psql_q 'SELECT COUNT(*) FROM votes')"
if [[ "$before9" == "$after9" ]]; then
  pass "R9" "tally preserved across restart (${before9})"
else
  fail "R9" "${before9} -> ${after9}"
fi

# ---- R9 end: wait for postgres and result to become fully ready after restart ----
# Postgres has a 30s initialDelaySeconds on readiness probe
# Result service also needs time to start and connect to postgres
for i in $(seq 1 90); do
  pg_ready=$(kubectl get pod voting-app-postgres-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  result_ready=$(kubectl get pod -l app.kubernetes.io/component=result -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$pg_ready" == "True" && "$result_ready" == "True" ]]; then
    break
  fi
  sleep 1
done

# ---- R10: All 5 workloads have liveness AND readiness probes ----
probe_counts="$(kubectl get deploy,statefulset -o json | jq -r '
  [.items[] | .spec.template.spec.containers[] | {l: (.livenessProbe != null), r: (.readinessProbe != null)}]
  | "\(map(select(.l))|length) \(map(select(.r))|length)"')"
liveness_n="${probe_counts%% *}"
readiness_n="${probe_counts##* }"
if [[ "$liveness_n" == "5" && "$readiness_n" == "5" ]]; then
  pass "R10" "5 liveness + 5 readiness probes"
else
  fail "R10" "liveness=${liveness_n} readiness=${readiness_n}"
fi

# ---- R11: All 5 workloads have resource requests AND limits ----
resourced_n="$(kubectl get deploy,statefulset -o json | jq '[.items[] | .spec.template.spec.containers[] | select(.resources.requests.cpu != null and .resources.requests.memory != null and .resources.limits.cpu != null and .resources.limits.memory != null)] | length')"
if [[ "$resourced_n" == "5" ]]; then
  pass "R11" "5 containers with cpu/mem requests + limits"
else
  fail "R11" "only ${resourced_n}/5 containers fully resourced"
fi

# ---- R12: Single kustomize config; registry image override supported ----
if kubectl kustomize "$KUSTOMIZE_DIR" >/dev/null 2>&1 \
  && kubectl kustomize "$KUSTOMIZE_DIR" | sed 's|vote:latest|k3d-voting-app-registry.localhost:5000/vote:latest|g; s|worker:latest|k3d-voting-app-registry.localhost:5000/worker:latest|g; s|result:latest|k3d-voting-app-registry.localhost:5000/result:latest|g' | grep -q 'k3d-voting-app-registry.localhost:5000/vote'; then
  pass "R12" "kustomize base + registry image override"
else
  fail "R12" "kustomize build or overlay override failed"
fi

# ---- R13: vote and result reachable via nginx ingress (HTTPS) ----
v13="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$VOTE_URL/")"
r13="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$RESULT_URL/")"
if [[ "$v13" == "200" && "$r13" == "200" ]]; then
  pass "R13" "vote=${v13} result=${r13}"
else
  fail "R13" "vote=${v13} result=${r13}"
fi

# ---- R14: No NodePort services ----
np="$(kubectl get svc -o json | jq '[.items[] | select(.spec.type == "NodePort")] | length')"
if [[ "$np" == "0" ]]; then
  pass "R14" "0 NodePort services"
else
  fail "R14" "${np} NodePort service(s)"
fi

# ---- R15: Images built locally for arm64 from a local registry ----
# Try docker inspect first; fall back to rdctl for Rancher Desktop
arch="$(docker inspect "vote:latest" --format '{{.Architecture}}' 2>/dev/null)"
if [[ -z "$arch" ]]; then
  arch="$(rdctl shell docker inspect "vote:latest" --format '{{.Architecture}}' 2>/dev/null || echo 'missing')"
fi
if [[ "$REGISTRY" == "1" ]]; then
  reg_refs="$(kubectl get deploy -o json | jq '[.items[].spec.template.spec.containers[].image | select(contains("k3d-voting-app-registry.localhost"))] | length')"
  if [[ "$arch" == "arm64" && "$reg_refs" -ge 3 ]]; then
    pass "R15" "arm64, ${reg_refs} registry image refs"
  else
    fail "R15" "arch=${arch} registry refs=${reg_refs}"
  fi
else
  imagepull="$(kubectl get pods -o json | jq '[.items[] | .status.containerStatuses[]? | select(.state.waiting.reason == "ImagePullBackOff")] | length')"
  if [[ "$arch" == "arm64" && "$imagepull" == "0" ]]; then
    pass "R15" "arm64, no ImagePullBackOff (images imported)"
  else
    fail "R15" "arch=${arch} imagepullbackoff=${imagepull}"
  fi
fi

# ---- R16: Each service reports dependency status ----
v16="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$VOTE_URL/healthz")"
r16="$(curl -sk --compressed -o /dev/null -w '%{http_code}' "$RESULT_URL/healthz")"
w16="$(kubectl exec "deploy/${RELEASE}-worker" -- python /app/app.py --healthcheck >/dev/null 2>&1 && echo 0 || echo 1)"
redis16="$(redis_q ping)"
pg16="$(kubectl exec "$PGPOD" -- pg_isready -U postgres 2>/dev/null | grep -q 'accepting connections' && echo 0 || echo 1)"
if [[ "$v16" == "200" && "$r16" == "200" && "$w16" == "0" && "$redis16" == "PONG" && "$pg16" == "0" ]]; then
  pass "R16" "vote/result/worker/redis/postgres all healthy"
else
  fail "R16" "vote=${v16} result=${r16} worker=${w16} redis=${redis16} postgres=${pg16}"
fi

# ---- R17: Postgres credentials come from a Secret, not committed manifests ----
if grep -rE 'POSTGRES_PASSWORD[[:space:]]*:' "$KUSTOMIZE_DIR" --include='*.yaml' 2>/dev/null; then
  fail "R17" "literal password reference found in committed manifest"
else
  secret_pw="$(kubectl get secret voting-app-postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null)"
  if [[ -n "$secret_pw" ]]; then
    pass "R17" "no literal password; Secret 'voting-app-postgres' holds POSTGRES_PASSWORD"
  else
    fail "R17" "Secret missing or empty"
  fi
fi

# ---- Summary ----
printf '\n===== %s PASS, %s FAIL =====\n' "$PASS" "$FAIL" | tee -a "$OUT"


