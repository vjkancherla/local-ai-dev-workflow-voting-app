# Active Context

Updated: 2026-08-23

## Current focus
Added a `Makefile` wrapping the four pipeline scripts, plus `docs/MAKEFILE-GUIDE.md` and a README
section. Verified the whole pipeline live: `make verify` → **17 PASS, 0 FAIL** (R1–R17).

## Recent changes
Created root `Makefile`: targets `build`, `deploy`/`up`, `verify`/`test`, `all`, `clean`/`down`,
`destroy`, `status`, `help`. `.EXPORT_ALL_VARIABLES` forwards `CLUSTER`/`REGISTRY`/`REGISTRY_PORT`/
`DELETE_CLUSTER`/`REMOVE_SECRETS`. Added `docs/MAKEFILE-GUIDE.md`; added README §4.4 + TOC entry.
Committed + pushed (8c92e0f). Ran `make verify` live: all 17 requirements pass.

## Next step
None blocking. Optional: wire `make` targets into any CI/automation; otherwise the pipeline is done.

## Active decisions
Wrapped scripts rather than reimplementing logic — `scripts/` stays the single source of truth.

## Blocked
none
