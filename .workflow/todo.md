# Todo

## 1. Verify app works after ingress + hostname change — DONE ✅
- Recreated the k3d cluster via `./scripts/deploy.sh` (k3d bundled Traefik, host ports 8081/8082, `.localhost` hostnames).
- Ran `./scripts/verify.sh` → **17 PASS, 0 FAIL (R1–R17)**. App is fully functional with `.localhost` resolution — no `/etc/hosts`, no nip.io.

## 2. Correct the false ingress lesson — DONE ✅
- Rewrote `.workflow/lessons.md` 2026-08-22 entry: the ingress has always used k3d's bundled Traefik (no nginx, no SSL passthrough, no TLS secret); hostnames now use `.localhost`.
- Updated README §5.5, README changelog, README "Ingress controller" note, and README "Gaps" table row.
- Fixed the stale `scripts/verify.sh` R13 comment (nginx → Traefik).
- Fixed `memory-bank/systemPatterns.md` (nginx Ingress → bundled Traefik; decision note).
- Updated stale nip.io URLs in `.workflow/PLAN-001-checkpointed-validation.md` to `.localhost`.
- Verified no remaining false "Traefik → nginx + SSL passthrough + nip.io" narrative in docs.

## 3. Commit + push outstanding changes — DONE ✅
- Committed all outstanding changes and pushed to origin/main.
