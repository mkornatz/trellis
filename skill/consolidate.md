# Trellis consolidate — the sleep pass

Fold an arc's durable signal up out of `## Log` into `## Context`, then drop the consolidated raw log. Like sleep: the day's raw experience becomes memory, the transcript is let go. Git retains every dropped block, so nothing is truly lost. On demand ("consolidate <arc>", "this log is huge") — the app never runs this on a timer; it's yours (and the user's) to invoke. Concepts/tools → `SKILL.md`.

## When

An arc whose `## Log` has outgrown its `## Context` — months of append-only entries, the durable decisions buried in chronology. Rehydration (`trellis_arc`) caps the log to its newest block, so a fat log doesn't bloat every fetch; consolidation is about the *record*, not the fetch: keeping Context true and the history lean. Signals: `trellis_arc` feels thin next to a long history, log entries that restate/supersede each other, decisions that live only in old log lines.

Skip: young arcs, arcs where the log is already sparse, `done`/`dropped` arcs (let them rest — or archive the whole arc instead).

## The bar — what rises, what's released

**Rises into Context** (the durable brief): decisions and why; the current state of the world; constraints, owners, dependencies, open questions that still stand; anything a fresh reader needs to act. State it in the present tense — Context is *what is true now*, not a diary.

**Released** (dropped from Log, kept by git): superseded intermediate states; day-to-day progress with no standing consequence; signals already folded into Context; noise. When unsure whether a fact still matters, fold it up — dropping is reversible via git, but a lost decision costs the arc its memory.

## Procedure (per arc)

1. **Rehydrate** — `trellis_arc <slug>`: current Context, tasks, latest log.
2. **Read the whole history** — `trellis_log <slug>`: every date block, oldest to newest.
3. **Synthesize** — write the **full new `## Context`**: existing durable context, plus everything from the log that still stands, restated as present-tense truth. This is your synthesis, not a copy — merge, dedup, supersede. You produce the prose; the app stores it verbatim (it has no LLM).
4. **Decide the cut** — how many recent date blocks to keep (`keep_log_blocks`). Keep enough that recent narrative isn't jarringly gone (≈2–4 blocks); everything older is now captured in Context and safe to drop.
5. **Apply** — `trellis_compact <slug> context:"<full new Context>" keep_log_blocks:<N>`. One committed step: Context replaced, old log dropped, `updated` bumped.
6. **Verify** — `trellis_arc <slug>`: Context reads as a true, self-contained brief; nothing load-bearing was lost.

## Rules

- **Full Context, not a fragment.** `context:` *replaces* the section. Omit something and it's gone from Context (git still has it). Always write the complete brief.
- **Synthesize, never invent.** Every durable claim traces to the log or prior Context. No new facts.
- **Git is the archive.** No separate archive file — dropped blocks live in history. Don't hedge by keeping everything; that defeats the pass.
- **Context is present-tense truth**, Log is dated events. Don't paste log lines into Context — restate them.
- **Idempotent.** Re-running a just-consolidated arc should be a near-no-op — if there's nothing new to fold and the log is already lean, leave it.
- **One arc at a time**, with judgment. This rewrites memory; it is not a batch job.

## Output

Report per arc: what rose into Context (1–2 lines), how many log blocks kept vs dropped. Nothing worth consolidating → say so, change nothing.
