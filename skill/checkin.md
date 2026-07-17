# Trellis check-in — the watcher

Sweep live arcs' sources for new activity since each arc's last log (ticket/PR comments, thread replies, watched-channel discussion, emails, calendar changes). When something needs a user decision, log a synthesized note and flag the arc 🔎. On demand ("check in on arcs") or scheduled. Concepts/tools → `SKILL.md`.

## The bar — flag only what needs a decision

Flag: reply/comment in a thread/ticket/PR the user is in; new related discussion in a watched channel; a blocker cleared (work can proceed) or a new blocker/risk/dependency; a deadline set or moved; a changed requirement/scope/upstream decision; a reason to reopen a done/paused arc; a direct ask on the user.

Never flag: routine progress, FYIs, cosmetic changes, noise; anything already in the log; your own reasoning with no new external input.

When unsure, don't — a false 🔎 costs attention, a skipped benign update costs nothing.

## Scope

Include active/waiting/paused arcs, any ⭐ priority, and done arcs updated within ~90 days. Exclude dropped arcs and older done arcs (unless one carries a watch-worthy source). Many arcs → active + waiting + priority first.

## Per arc

1. Rehydrate (`trellis_arc <slug>`): context, tasks, recent log, sources, links.
2. Find sources — the arc's `sources` (`url:`/`pr:`/`ticket:`) and linked people/system roots say where to look.
3. Check them with your tools for activity since the last log date.
4. Judge against the bar.
5. Meaningful and not already logged:
   - `trellis_append_log` — **Signal** (what's new, sourced) · **Why** (the stakes) · **Suggested** (decision/next step).
   - `trellis_set_review <slug> on` with a one-line `note` → becomes `flag_note`, shown in `overview` and the decision inbox; the user clears it on review.
6. Else leave it — never log "nothing changed."

## Rules

- Never change an arc's status — flag it, the user decides.
- You fetch and synthesize; the tools only store. Never dump raw content.
- Idempotent — don't re-flag a signal already 🔎 or repeat a logged note; re-flag only on a materially new development.
- One capsule per signal. Terse. Sourced.

## Output

Report arcs newly flagged (one-line reason each) and how many swept; nothing to flag → say so. Headless runs: some connectors need interactive auth — note an unreachable source, don't silently skip it.
