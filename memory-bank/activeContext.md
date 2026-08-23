# Active Context

Updated: 2026-08-23

## Current focus
Removed the dead `nip.io` dependency: app hostnames now use the `.localhost` TLD, which resolves to
127.0.0.1 natively (RFC 6761) — no `/etc/hosts` entry, no external DNS.

## Recent changes
Rolled out `.localhost` resolution across the repo. `kustomize/ingress.yaml` host rules and `verify.sh`
URLs now use `vote.localhost`/`result.localhost` (was `vote.127.0.0.1.nip.io`). Rewrote all `/etc/hosts`
setup instructions in `scripts/deploy.sh`, `scripts/verify.sh`, `README.md`, `docs/SCRIPTS-GUIDE.md`,
`docs/MANUAL-TESTING-GUIDE.md` to explain native resolution; `getent` checks → `nslookup`. Removed stale
`scripts/verify.sh.bak`.

## Next step
Re-run `./scripts/deploy.sh` to apply the updated ingress, then `./scripts/verify.sh` to confirm R1–R17.

## Active decisions
Adopted `.localhost` (RFC 6761) instead of `nip.io` + `/etc/hosts`: native resolution, no external DNS,
no per-name hosts entries. Ingress routes on the Host header, so only the client needs resolution.

## Blocked
none
