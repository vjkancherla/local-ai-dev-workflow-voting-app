# Project Brief

## Purpose
A distributed voting web app (Flask `vote` → Redis → Python `worker` → Postgres → Flask `result`) that demonstrates a message-queue pipeline with idempotent processing and near-real-time results.

## Requirements
17 verifiable requirements (R1–R17) in `.workflow/requirements.md`: functional (R1–R6), data durability (R7–R9), and platform/Kubernetes hardening (R10–R17).

## Out of scope
Authentication, TLS, multi-tenancy, horizontal autoscaling, monitoring stack, real-time push, and migrations framework.

## Success criteria
Every R1–R17 check passes and is recorded in `.workflow/verify.md`.
