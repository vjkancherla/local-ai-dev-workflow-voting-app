# Makefile Guide — Voting App

> The `Makefile` at the repo root wraps the four scripts in `scripts/`
> (`build.sh`, `deploy.sh`, `verify.sh`, `cleanup.sh`). It exists so you can run the
> build → deploy → verify → teardown pipeline with short `make` targets instead of
> remembering script paths, flags, and environment variables.
>
> 👉 This doc is the *operator's* companion for `make`. For the scripts themselves
> (what each does, every env var, troubleshooting), see
> [`SCRIPTS-GUIDE.md`](SCRIPTS-GUIDE.md). For the human, requirement-by-requirement
> walkthrough (R1–R17), see [`MANUAL-TESTING-GUIDE.md`](../MANUAL-TESTING-GUIDE.md).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Target Reference](#target-reference)
4. [Common Workflows](#common-workflows)
5. [Environment Variables](#environment-variables)
6. [How Passthrough Works](#how-passthrough-works)
7. [Troubleshooting](#troubleshooting)
8. [Quick Reference](#quick-reference)

---

## Prerequisites

`make` must be on your `PATH`. Everything the scripts need (Docker, k3d, kubectl, jq, openssl)
is a prerequisite of the scripts themselves — see [`SCRIPTS-GUIDE.md`](SCRIPTS-GUIDE.md#prerequisites).

```bash
make --version        # make 3.81+ (macOS ships 3.81; Homebrew has a newer one)
```

## Quick Start

The normal loop is **deploy → verify**:

```bash
make all              # deploy.sh (builds automatically) then verify.sh
```

That single target is equivalent to `./scripts/deploy.sh && ./scripts/verify.sh`, but with
consistent env-var handling and a shorter thing to type.

Get an overview of every target anytime:

```bash
make help
```

---

## Target Reference

| Target | Runs | Description |
|--------|------|-------------|
| `make help` | — | List all targets + a passthrough note (default goal) |
| `make build` | `scripts/build.sh` | Build the 3 images (`vote`/`worker`/`result`, `linux/arm64`) and load them into the cluster |
| `make deploy` | `scripts/deploy.sh` | Create cluster (if missing), build + load images, apply Kustomize, wait for ready. Alias: `up` |
| `make verify` | `scripts/verify.sh` | Run R1–R17, print a PASS/FAIL summary, append to `.workflow/verify.md`. Alias: `test` |
| `make all` | deploy → verify | The full build → verify loop (the recommended starting point) |
| `make clean` | `scripts/cleanup.sh` | Delete the deployed Kubernetes resources (safe to repeat). Alias: `down` |
| `make destroy` | `scripts/cleanup.sh DELETE_CLUSTER=1 REMOVE_SECRETS=1` | Full teardown: resources, then the k3d cluster and the secret file |
| `make status` | `kubectl get pods,svc,ingress` | Show cluster pods, services, and ingress |

**Idiom:** `deploy` → `verify` to ship and check; `clean`/`destroy` to tear down.

---

## Common Workflows

**Fresh start (everything):**
```bash
make all
```

**After changing app code (vote/worker/result):** `deploy.sh` rebuilds automatically, so this
rebuilds the images and re-applies manifests, then verifies:
```bash
make all
```

**Just rebuild + load images (no manifest change):**
```bash
make build
```

**Re-verify only (cluster already running):**
```bash
make verify
```

**Cluster status check:**
```bash
make status
```

**Registry mode (port 5000 busy):**
```bash
make deploy REGISTRY=1 REGISTRY_PORT=5001
make verify REGISTRY=1        # so R15 checks registry refs, not image imports
```

**Custom cluster name:**
```bash
make deploy CLUSTER=mycluster
```

**Clean up / teardown:**
```bash
make clean                    # delete k8s resources only
make destroy                  # also delete the k3d cluster and secret file
```

---

## Environment Variables

Every variable the scripts accept is forwarded by the `Makefile`. Defaults match the scripts.

| Variable | Script(s) | Default | Purpose |
|----------|-----------|---------|---------|
| `CLUSTER` | build.sh, deploy.sh | `voting-app` | k3d cluster name |
| `REGISTRY` | build.sh, deploy.sh, verify.sh | `0` | `1` = registry mode (push to cluster registry instead of import) |
| `REGISTRY_PORT` | build.sh, deploy.sh | `5000` | Host port for the k3d registry (change if AirPlay claims 5000) |
| `DELETE_CLUSTER` | cleanup.sh | `0` | `1` = also `k3d cluster delete` after removing resources |
| `REMOVE_SECRETS` | cleanup.sh | `0` | `1` = also delete `kustomize/postgres-secret.env` for a fresh start |

(Other script-only variables — `KUSTOMIZE_DIR`, `RELEASE`, `VOTE_URL`, `RESULT_URL`, `PGPOD`,
`OUT` — are used by `verify.sh` internally with their defaults; override them by editing the
script.)

---

## How Passthrough Works

The `Makefile` sets `.EXPORT_ALL_VARIABLES:`, so **any** variable in the `make` environment is
exported into the recipe shell and therefore seen by the underlying script as its own env var.
You can pass a variable two equivalent ways:

```bash
# 1. Shell-export form (variable lives in your shell)
REGISTRY=1 make deploy

# 2. make command-line form (variable lives in make)
make deploy REGISTRY=1
```

Both end up running `./scripts/deploy.sh` with `REGISTRY=1` in its environment. Form 1 is
preferred when the variable is a property of your machine (e.g. you always use registry mode);
form 2 is convenient for one-off runs.

> **Note:** `make -n <target> VAR=1` prints only the command line (`./scripts/deploy.sh`) — the
> variable is applied at runtime, not echoed. To confirm a variable reaches a script, run the
> target for real (or point `DEPLOY` at a probe script: `make deploy DEPLOY=/tmp/probe.sh`).

---

## Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `make: command not found` | `make` isn't installed. On macOS: `brew install make` (or Xcode Command Line Tools). |
| `make: *** <target> Error 127` | The script isn't executable or isn't found. `scripts/*.sh` are `755`; if you restored them from git with wrong perms, run `chmod +x scripts/*.sh`. |
| Env var seems ignored | Use one of the two forms in "How Passthrough Works". Command-line `make target VAR=1` and shell-export `VAR=1 make target` are equivalent. |
| `verify.sh` can't reach the app over HTTPS | `.localhost` isn't resolving on this machine — see [`SCRIPTS-GUIDE.md`](SCRIPTS-GUIDE.md#environment-setup). Check with `nslookup vote.localhost`. |
| `ImagePullBackOff` in import mode | Images weren't imported — re-run `make build`, then `make verify`. In registry mode, confirm `REGISTRY=1` was used consistently. |
| Port 5000 already in use | AirPlay Receiver on macOS. Use `make deploy REGISTRY=1 REGISTRY_PORT=5001`. |

---

## Quick Reference

| Goal | Command |
|------|---------|
| Build the images | `make build` |
| Deploy (cluster + images + manifests) | `make deploy` (alias `up`) |
| Full automated verification (R1–R17) | `make verify` (alias `test`) → `.workflow/verify.md` |
| Deploy then verify (the normal loop) | `make all` |
| Cluster status | `make status` |
| Tear down the deployment | `make clean` (add `make destroy` for full teardown) |
| Registry mode | `make deploy REGISTRY=1` |

**Tip:** `deploy.sh` builds automatically, so the normal loop is `make all`. Use `make build`
directly only when you've changed app code and want to reload images without re-applying manifests.
