---
name: trellis
description: Context-native work-memory — a knowledge graph of **arcs** (work with a lifecycle: context, tasks, log, `[[links]]`) and **roots** (reference with no lifecycle; people, systems, docs). Read it to see what's in flight, write back what you learn. Use when the user names an ongoing initiative/project, asks to capture/log/remember work, wants to rehydrate a thread, asks what's open or awaited, or before researching something the vault may hold. Interfaces: `trellis` CLI (on PATH) and `mcp__trellis__*` tools. Triggers: arcs, roots, work notes, unfamiliar initiative names.
---

# Trellis — context-native work memory

Shared brain for ongoing work. The user captures decisions/findings; you read to see what's in flight and write back what you learn.

Markdown vault (`~/trellis/`, override `TRELLIS_VAULT`) is the source of truth; the SQLite index is derived and disposable; every write commits to git. Go through the CLI or MCP tools — never touch the index, prefer tools over hand-editing.

## Two node types

**Arc** — a line of work that *starts and finishes* (`billing-v2`, `search-rebuild`): moves through a status, then completes. Sections: `## Context` (dense gist, rewritten as reality shifts), `## Tasks` (checkboxes), `## Log` (append-only synthesized entries, newest first), plus `[[links]]`. Frontmatter: `title, status, tags, sources, created, updated, priority, needs_review, synopsis, flag_note, pinned`.

**Root** — durable reference that *accumulates but never finishes* (finances, prefs, vendors, a system's history). **People, systems, principles are roots.** Has `## Context` + optional `## Log` — no tasks, no status/priority/review. Frontmatter subset: `title, kind, tags, created, updated, synopsis, pinned`. Classify with the `kind` facet (`system|person|principle|…`, coin freely) — a facet, not a folder; filter via `trellis roots [--kind <k>]`.

**Which?** Finishes / has progressing tasks → arc. Reference you return to, no start or end → root. Unsure → arc (can be marked `done`); never file durable reference as an arc that hangs open forever.

## The graph

`[[links]]` are edges. Bare `[[snowflake]]` resolves by basename (use for roots); path-qualified `[[arcs/search-rebuild]]`, `[[artifacts/2026/07/06-…]]` classify the edge by leading segment. `trellis related <slug>` walks it; rehydrating a node surfaces its links + backlinks. Missing target → create the node so `doctor` stays clean.

## Flags — three binary switches, orthogonal to status and each other (none bump `updated`)

- **`priority`** — focus set; floats to top of `list`. Volatile, re-triaged often.
- **`needs_review`** (🔎) — decision inbox. Set on a fresh signal needing the user's call (incl. reopening a done/paused arc). **Top sort tier** — surfaces regardless of status. Reason → `flag_note`; full note → log.
- **`pinned`** — renders into `pinned.md`, loaded every session. **Pin sparingly** (hard line budget).

## Statuses (arcs only)

`active | waiting | paused | done | dropped`. Only **active** shows in the default `trellis tasks` view. **paused** = backlog/someday — takes a whole line of work off the plate; its tasks stay one `--all`/`--arc` away.

## Commands

Prefer `mcp__trellis__*` tools when present (same behavior, no shell). Else use the CLI — don't get stuck.

```
trellis overview                    # orient: each arc's synopsis + status (+ review reason)
trellis list [--status active]      # arcs: 🔎 review → ⭐ priority → status → recency
trellis search "<terms>"            # arcs + roots + artifacts by keyword
trellis arc <slug|prefix>           # rehydrate arc: context, open tasks, recent log, links, backlinks
trellis root <slug|prefix>          # rehydrate root (no tasks)
trellis roots [--kind system|…]     # list roots, optional kind filter
trellis tasks [--waiting|--due|--arc X|--all]   # open tasks; default = active arcs only
trellis related <slug>              # graph neighbors
trellis log <slug>                  # full ## Log history (all date blocks); trellis arc caps to the latest
trellis new "<title>" --area <x> [--tags a,b]   # create arc
trellis new "<title>" --kind roots [--area <x>] # create root
trellis capture "<note>" --arc <slug>   # append to arc log (--root for root; omit both → inbox); always logs daily
trellis add-task <slug> "<text> @due(2026-07-15) @waiting(who)"
trellis compact <slug> [--keep N]   # consolidate: new ## Context via STDIN and/or drop old log blocks
trellis priority <slug> [on|off]
trellis review [<slug> [on|off]]    # no arg: decision inbox
trellis pin <slug> [on|off]         # pin SPARINGLY
trellis artifacts                   # long-form docs + backlinks
trellis doctor                      # drift check (dangling links, frontmatter errors)
trellis reindex                     # rebuild index after a direct file edit
trellis init                        # one-time setup
```

MCP equivalents: `trellis_overview, _list_arcs, _search, _arc, _root, _roots, _tasks, _related, _log, _capture, _append_log, _add_task, _compact, _new_arc, _new_root, _set_priority, _set_review, _pin`.

## Searching

`search` is lexical (bm25 + stemming) — it matches **words, not meaning**. It won't surface an arc that phrases the same idea differently (searching "authentication" misses one that only says "login flow"). So:

- **Reformulate, don't single-shot.** A concept search → try 2–3 phrasings (synonyms + the underlying concept), not one query.
- **Pair with `overview`.** Synopses are cheap and you judge relevance better than keyword rank — read them, don't trust the hit list alone.
- **Thin results ≠ not there.** Before deciding an initiative is new (and creating a duplicate arc), widen the phrasing or skim `list`. At this vault size, reading every title costs nothing.

## Working loop

1. **Brain-first.** Before researching/planning/answering about ongoing work, check trellis (`overview` → `search`/`arc`). Unfamiliar initiative → search before assuming it's new.
2. **Rehydrate** the arc/root before picking up a thread.
3. **Synthesize, never dump.** Trellis does no fetching and no LLM. *You* fetch signals with your own tools and write a clean 2–5 bullet capsule (what happened / why it matters / what changed). Never paste raw content.
4. **Capture back** to the arc log after working it — one capsule per signal, terse, sourced.
5. **Prune when heavy** (below).

## Conventions

- **Slugs:** `<area>-<name>`; resolve by unique prefix; derived from the title on `new`.
- **Tasks:** `- [ ] text` + optional `@due(YYYY-MM-DD)`, `@waiting(who)`, `@blocked`, `@paused`; `- [x]` = done.
- **`kind`:** MCP → pass `kind:` to `trellis_new_root`. CLI → `trellis new … --kind roots`, set `kind:` in frontmatter, `reindex`.
- **`synopsis`** = one-line gist (distinct from title); **`flag_note`** = why `needs_review` is set. Set by editing frontmatter + `reindex`; neither bumps `updated`.

## Direct edits & pruning

No verb sets `## Context` for a small tweak — edit `~/trellis/arcs/<slug>.md` (or `roots/…`) directly by absolute path, then **`trellis reindex`**. Append ops (log/tasks) reindex automatically.

Pruning is **your** job (the app never rewrites) — keep arcs dense and accurate as they age, not smaller for its own sake: rewrite a drifted `## Context`, collapse near-duplicate/superseded log lines, drop long-done tasks. Every write commits, so an over-cut is one `git revert` away — prune boldly when an arc *feels* heavy, not on a schedule.

For the heavy case — an arc whose `## Log` has outgrown its `## Context` — use **consolidation** (`trellis_compact`) rather than hand-editing: fold the durable signal up into Context and drop the consolidated raw log in one committed step. Procedure → **`consolidate.md`**.

## Artifacts

Long-form docs (RFCs, plans, research, handoffs) live in `~/trellis/artifacts/YYYY/MM/DD-<title>.md`, sharded by *creation* month (never moves). Link from an arc with `[[artifacts/YYYY/MM/DD-<title>]]`; **don't paste long docs into `## Context`** (it breaks the terse rehydration capsule). `search` covers their content; rehydrating an arc surfaces linked artifacts. Read/write as plain files by absolute path.

## Check-in

On demand ("check in on arcs") or scheduled, sweep live arcs for fresh external signal and flag those needing a decision (🔎). Procedure → **`checkin.md`**.

## When NOT to use

Trivial one-offs, scratch reasoning, noise — capture signal, not clutter. **Never turn routine dev/env chores into arc tasks** (pull/rebase, install deps, run migrations, restart a service): mechanics, not work-memory. If a chore blocks, just do it. Capture only the decision or finding it surfaced.
