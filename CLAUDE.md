# Trellis

Context-native work-memory. Durable **arcs** (initiatives/projects) hold context, tasks, a log, and `[[links]]`; the links form a knowledge graph of projects, decisions, people, and systems. It is a shared brain for ongoing work and the substrate agents read to understand what's in flight and write back what they learn.

This repo is the **tool** (CLI + MCP server). The **vault** it operates on is a separate Markdown directory at `~/trellis` (override `TRELLIS_VAULT`). Code here, data there.

## Mental model

Markdown is the truth. Everything else derives from it or writes back to it.

```
Markdown vault (~/trellis)  ──parse──▶  Arc  ──index──▶  SQLite (.trellis/index.db)
      ▲                                                        │
      └──────────── Store (write) ◀── CLI / MCPServer ──read──┘
                         │
                       Git (commit every write)
```

- **`arc.rb`** — read-only parser: one Markdown file → structured data (frontmatter, sections, tasks, links, sources, log). The file is the source of truth.
- **`store.rb`** — the only write path: every mutation produces Markdown, then the caller reindexes. No fetching, no synthesis.
- **`index.rb`** — SQLite, derived and disposable; `reindex` rebuilds it from the vault.
- **`git.rb`** — commits the vault on each write so state is never more than one action from safe.
- **`config.rb`** — vault paths + the graph vocabulary (`node_dirs`: arcs, roots, artifacts).

**Arcs vs roots.** Arcs are time-bound threads of work with a start and an end (they progress through a lifecycle and complete). Roots are durable ground some arcs grow from and others never touch — reference/context that accumulates but never "finishes" (finances, prefs, a car's history). Roots share the arcs table via a `kind` column (arc|root) but carry no status, tasks, priority, or review; they surface through `search`, `trellis root <slug>`, `trellis roots`, and `[[links]]`, not through `list`. People and systems are just roots — reference nodes carrying a user-driven `entity_kind` facet (frontmatter `kind:` = system|person|principle|…), orthogonal to arc|root; filter with `trellis roots --kind <k>`.
- **`cli.rb`** (Thor, human) and **`mcp_server.rb`** (agents, stdio) are thin shells over `Store`/`Index`/`Arc`.

## Invariants

These protect the design. Preserve them; if a task seems to require breaking one, stop and flag it.

1. **Markdown is authoritative; the index is derived.** Any state must survive deleting the DB and running `reindex`. Never store truth only in SQLite.
2. **The app has no LLM and does no fetching.** Agents supply already-synthesized content; capture/log tools take finished prose, not raw dumps or URLs.
3. **Every write commits git, and the app authors the message** from action + slug + `Git.summarize` — callers never pass commit text.
4. **`[[links]]` are the graph.** Each link becomes an edge whose `kind` is its leading path segment (`arcs/`, `roots/`, `artifacts/`, else `other` — a bare `[[slug]]`, e.g. a link to a reference node, resolves by basename). Graph features build on the `edges` table, not on prose scanning.
5. **Priority, needs-review, and pinned are binary flags,** orthogonal to lifecycle status and to each other. `list` ordering is `review → priority → status → recency`; no manual ranking or numeric scores. `needs_review` is the top tier so a done/paused arc with a fresh signal still surfaces (the "reopen?" case); the check-in watcher sets it, the human clears it. `pinned` renders an entity into `pinned.md` (a derived digest imported into `~/.claude/CLAUDE.md`, so pinned context loads every session); keep the pinned set small — the file has a hard line budget.
6. **One core, two interfaces.** Behavior lives in `Store`/`Index`/`Arc` so CLI and MCP stay in lockstep. Don't put logic in a Thor command or MCP tool the other can't reach.

## Vault layout (`~/trellis`)

```
arcs/<area>-<slug>.md   durable work — frontmatter + ## Context / ## Tasks / ## Log
roots/<slug>.md         durable reference/context — no lifecycle (## Context / ## Log); may nest in subfolders; people/systems/principles live here, typed by frontmatter kind:
artifacts/YYYY/MM/<slug>.md  long-form docs (plans, RFCs); sharded by first-added month; FTS-only, linked from arcs
daily/, inbox/          append-only activity log and unrouted captures
pinned.md               derived digest of pinned arcs/roots, imported into ~/.claude/CLAUDE.md
.trellis/index.db       derived index (gitignored in the vault)
```

Arc frontmatter: `title, status (active|waiting|paused|done|dropped), tags, sources, created, updated, priority, needs_review, synopsis, flag_note, pinned`. `synopsis` is a one-line gist (distinct from `title`); `flag_note` explains why `needs_review` is set. Root frontmatter is a subset: `title, kind, tags, created, updated, synopsis, pinned` (no lifecycle fields); `kind` is the user-driven facet (system|person|principle|…). Inline task annotations in `## Tasks`: `@due(YYYY-MM-DD)`, `@waiting(who)`, `@blocked`, `@paused`.

## Development

- Ruby **3.4.7** (`.ruby-version`).
- `rake` runs the tests. Each test points `TRELLIS_VAULT` at a tmpdir, so the real vault is never touched — keep that isolation.
- `bin/trellis mcp` starts the stdio server agents connect to; `bin/trellis doctor` reports vault↔index drift (dangling `[[links]]`, frontmatter errors) — run it after changing parsing or indexing.
- Adding an operation usually spans all four layers: a `Store` write, an `Index` change if it's queryable, a CLI command, and an MCP tool — reindex the touched arc, then `Git.commit`.
- `skill/` holds the canonical `trellis` agent skill (`SKILL.md` + `checkin.md`); it's symlinked into `~/.claude/skills/trellis` so agents load it from any repo (`ln -s "$PWD/skill" ~/.claude/skills/trellis`). Edit it here, not there. Keep it in sync when CLI/MCP surface changes.
