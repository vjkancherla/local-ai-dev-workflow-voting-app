# Active Context

Updated: 2026-08-23

## Current focus
Added a `Makefile` that wraps the four pipeline scripts (`build.sh`, `deploy.sh`, `verify.sh`,
`cleanup.sh`) from `docs/SCRIPTS-GUIDE.md` with convenience targets and env-var passthrough.

## Recent changes
Created `Makefile`: targets `build`, `deploy`/`up`, `verify`/`test`, `all` (deploy+verify),
`clean`/`down`, `destroy` (full teardown), `status`, `help`. `.EXPORT_ALL_VARIABLES` forwards
`CLUSTER`, `REGISTRY`, `REGISTRY_PORT`, `DELETE_CLUSTER`, `REMOVE_SECRETS` to the scripts.
Verified with `make help` and `make -n`.

## Next step
Optional: commit the Makefile, then re-run `./scripts/deploy.sh` + `verify.sh` for live R1–R17.

## Active decisions
Wrapped scripts rather than reimplementing logic — single source of truth stays in `scripts/`.

## Blocked
none
