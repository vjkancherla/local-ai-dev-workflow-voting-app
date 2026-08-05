# Agent rules

## Core principles
- Simplicity first. Minimal code, minimal blast radius.
- No laziness. Root causes, not workarounds. Senior standards.
- Minimal impact. Touch only what the task names.
- YAGNI. Nothing speculative.

## Artifacts
Phase outputs live in .workflow/. Read before writing.

  requirements.md  design.md  tasks.md  review.md  verify.md  lessons.md

- Never rewrite another phase's file. Append under a dated heading.
- lessons.md is the only file any phase may append to freely.
- This file (AGENTS.md) is human-maintained. Propose changes in lessons.md;
  do not edit it.

## Gates
Each phase ends at a checkpoint the human signs. Never start the next phase.
Stop, summarise what changed, and wait.

## Per-phase rules

### Design / Tasks
- Read requirements.md first. Nothing outside it. Nothing from "Out of scope".
- Every decision names the requirement ID it serves.
- Write detailed specs; ambiguity resolved here is not guessed at later.
- Before presenting: is there a simpler design? Challenge your own work.
- Do not write code.

### Implement
- Read design.md and tasks.md first.
- One task at a time. Mark complete in tasks.md only after its own check passes.
- Autonomous within an approved task: read the logs, find the cause, fix it,
  don't ask. Never autonomous across a gate or beyond the task's named files.
- If the task turns out to need 3+ unplanned steps or an architectural
  decision: STOP. Write the problem to lessons.md and return to the gate.
  Do not keep pushing.
- If a fix feels hacky, say so and implement the clean version instead.
  Do not over-engineer.

### Review
- Scope: correctness, edge cases, missing validation, error handling.
- Not architecture. Not style preference.
- Findings numbered, with severity, referencing files and lines.

### Verify
- Nothing is done until it is proven. Run it, capture actual output.
- Record command and output in verify.md, per requirement ID.
- No requirement is passed on inspection alone.
- From the second feature onward: diff behaviour against the previous commit.

## Lessons
Append to lessons.md whenever the human corrects an approach, with the rule
that would have prevented it. Review lessons.md at the start of every phase.