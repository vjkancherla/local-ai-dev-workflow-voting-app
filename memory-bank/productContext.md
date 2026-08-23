# Product Context

## Problem
A reference distributed-voting system that exercises queueing, idempotency, and durability guarantees in a self-contained, locally-runnable stack.

## Users
Local developers/reviewers on macOS arm64 who build, deploy to k3d, and run the R1–R17 verification harness.

## Behaviour
The vote page enqueues a per-browser vote; the worker drains Redis and upserts Postgres idempotently; the result page polls Postgres and shows counts and percentages. All workloads expose `/healthz`, liveness/readiness probes, and resource limits.
