# Voting App — Lessons Log

## 2026-08-12 — Deployment tool: Helm → Kustomize (human override)

The original plan (`.omo/plans/synthesis.md`) specified a single Helm chart.
The human redirected to **Kustomize** instead.

Implications applied:
- Helm `templates/` + `values.yaml` replaced with `kustomize/` base manifests +
  `kustomization.yaml`, plus `kustomize/overlays/registry/` for image overrides.
- Secret generation: Helm `lookup` + `randAlphaNum` + `helm.sh/resource-policy:
  keep` replaced with Kustomize `secretGenerator` reading a gitignored
  `postgres-secret.env` (created once by `scripts/deploy.sh`, `openssl rand
  -hex 16`). `generatorOptions.disableNameSuffixHash: true` keeps the Secret
  name stable across applies.
- `scripts/deploy.sh`: `helm upgrade --install` → `kubectl apply -k`.
- `scripts/verify.sh` R12/R17: `helm template`/`helm lint` and `values.yaml`
  checks → `kubectl kustomize` (base + registry overlay) and a grep over
  committed YAML for a literal password.

Rule that would have avoided the rework: confirm the deployment/config tool
(Helm vs Kustomize) with the human before generating chart templates, since the
requirement R12 ("one Helm chart") encodes a tool choice the human may change.

## 2026-08-22 — Ingress switch: Traefik → nginx + SSL passthrough + nip.io

The E2E verify script was failing because ports 80 and 8080 were already in use
on the host (AirPlay Receiver claimed 80; another service occupied 8080). The
Traefik ingress (which listens on those ports by default) could not bind.

Changes made:
- Recreated the k3d cluster with explicit loadbalancer port mappings:
  `8081:80` (HTTP) and `8082:443` (HTTPS).
- Replaced the Traefik ingress with an **nginx ingress controller** installed
  via Helm (`ingress-nginx/ingress-nginx`).
- Rewrote `kustomize/ingress.yaml` for nginx:
  - `ingressClassName: nginx`
  - `ssl-passthrough: "true"` + `ssl-redirect: "true"` for HTTPS backends.
  - `nginx.ingress.kubernetes.io/backend-protocol: "HTTP"` (apps listen on
    port 80, not 443 — the TLS termination happens at the ingress).
  - `pathType: ImplementationSpecific` (required for SSL passthrough with
    nginx; `Prefix`/`Exact` do not work).
- Switched hostnames to **nip.io** domains:
  `vote.127.0.0.1.nip.io` and `result.127.0.0.1.nip.io`. These auto-resolve
  to `127.0.0.1`, eliminating the need for `/etc/hosts` entries.
- Generated a self-signed TLS certificate (`/tmp/tls.crt` + `/tmp/tls.key`)
  and created a Kubernetes `Secret` (`voting-app-tls`) for the ingress.
- Updated `scripts/deploy.sh` to install nginx ingress, create the TLS secret,
  and use HTTPS URLs on port 8082.
- Updated `scripts/verify.sh` to use nip.io HTTPS URLs, added `-k` flag to all
  `curl` calls (self-signed certs), and fixed a few verify-script bugs:
  - R2: Accept HTTP 302 (Flask `redirect()` response) alongside 200.
  - R12: Use `sed`-based image override instead of `kubectl kustomize` overlay
    (the `../..` reference in the overlay causes a cycle with `kubectl kustomize`).
- Added retry logic (`_connect_with_retry()`) to `result/app.py` to handle
  transient Postgres connection failures under the verify script's rapid polling.

Rule that would have avoided the initial port conflict: probe host port
availability (80/443 or 8080/8443) before selecting ingress ports, or use a
random high port for the loadbalancer and document it.

