# Trellis

Context-native work memory. Trellis keeps your ongoing work in durable **arcs**, one per initiative, project, or investigation, each holding context, tasks, a running log, and `[[links]]` to the people, systems, and other arcs it touches. Those links form a knowledge graph you and your agents can traverse.

It is built as shared memory between you and your AI coding agents. You drive it from the `trellis` CLI; agents drive it over MCP. The vault is plain Markdown you own, so nothing is trapped in a database or a hosted service.

Trellis is a generic tool. Nothing about it is tied to a company or a workflow: an arc can be a work project, a research thread, a home renovation, or a novel in progress.

## The idea

- **Arcs are the unit.** An arc is a durable line of work that accumulates context over weeks or months. It carries a status, a body of context, open tasks, and a dated log, so picking a thread back up means reading one file.
- **Markdown is the truth.** Everything is a plain `.md` file. The SQLite index is derived and disposable: delete it and `trellis reindex` rebuilds it from the vault.
- **The tool has no LLM and does no fetching.** Agents supply already-synthesized prose; Trellis stores, indexes, links, and retrieves it. The intelligence lives in whatever agent is using it.
- **Links are the graph.** Each `[[people/...]]`, `[[systems/...]]`, or `[[arcs/...]]` reference becomes an edge, so related work and shared entities surface without manual cross-referencing.
- **Every write commits git**, so state is never more than one action away from safe.
- **One core, two interfaces.** A Thor CLI for humans and an MCP stdio server for agents sit over the same read/write core, so both stay in lockstep.

## Concepts

The vault is made of a few kinds of nodes. Knowing which is which is most of the mental model.

- **Arc** — the core unit: a durable *line of work* with a beginning and an end. Migrating billing to v2, rebuilding search, planning a move. An arc carries a lifecycle `status` (`active` → `waiting`/`paused` → `done`/`dropped`), a body of `## Context`, open `## Tasks`, and a dated `## Log`. It accumulates over weeks or months, and picking the thread back up means reading one file. Arcs are what `list`, `overview`, and `tasks` operate on.

- **Root** — durable *reference or context* with no lifecycle: it accumulates but never finishes. Household finances, dietary preferences, a car's maintenance history, travel notes. A root has `## Context` and an optional `## Log`, but **no tasks and no status** — if a root ever needs an actionable task, that work has become an arc. Roots are the ground some arcs grow from and others never touch. They don't appear in `list`; you reach them through `search`, a direct `root <slug>` read, or a `[[link]]` from an arc. Roots may nest in subfolders (`roots/finances/accounts.md`).

  *Arc vs root, in one line:* an arc is a thread you'll finish; a root is a place you keep coming back to.

- **Artifact** — a long-form document (plan, RFC, research writeup) that's too big to live inside an arc's Context. Artifacts are searchable and linked from arcs with `[[artifacts/<slug>]]`, keeping the arc itself a terse rehydration capsule.

- **People / Systems** — lightweight graph nodes (`[[people/jordan-lee]]`, `[[systems/payments-api]]`) that arcs reference. Shared references are how `related` surfaces connected work.

- **Link (`[[…]]`)** — every bracketed reference becomes an edge in the knowledge graph, classified by its leading path segment (`arcs/`, `roots/`, `people/`, `systems/`, `artifacts/`). The graph is what makes backlinks and "related work" fall out for free.

Three **binary flags** sit orthogonal to status, each a simple on/off lens rather than a score:

- **priority** — the focus set; flagged arcs float to the top of `list`. Meant to churn week to week.
- **needs_review** — the decision inbox. A watcher flags an arc when a fresh external signal warrants your decision (a `flag_note` records why); you clear it once you've looked. It's the top sort tier, so even a *done* arc with a live signal resurfaces ("reopen?").
- **pinned** — renders an arc or root into `pinned.md`, a small derived digest imported into your `~/.claude/CLAUDE.md` so that context loads into *every* session. Pin sparingly: the file has a hard size budget.

## Install

Requirements: Ruby 3.4.7 (see `.ruby-version`).

```sh
git clone git@github.com:mkornatz/trellis.git
cd trellis
bundle install
ln -s "$PWD/bin/trellis" /usr/local/bin/trellis   # put it on PATH
```

The vault defaults to `~/trellis`; override it with the `TRELLIS_VAULT` environment variable. Directories are created on first write. To turn on automatic commits, make the vault a git repository:

```sh
mkdir -p ~/trellis && git -C ~/trellis init
```

## Usage

```sh
trellis init                        # create vault dirs, build the index, wire pinned.md into ~/.claude/CLAUDE.md
trellis new "Migrate billing to v2" --area billing --tags infra
trellis new "Household finances" --kind roots --area home   # a root: durable reference, no lifecycle
trellis arc billing                 # rehydrate: context, open tasks, recent log, links, backlinks
trellis root home/household-finances   # rehydrate a root: context, log, links, backlinks
trellis list                        # arcs, ordered review → priority → status → recency
trellis overview                    # quick glance: each arc's synopsis + status (+ review reason)
trellis capture "Decided to cut over region by region" --arc billing
trellis capture "Refinanced, new account at X" --root home/household-finances
trellis add-task billing "Draft cutover plan @due(2026-07-20)"
trellis tasks                       # open tasks across active arcs
trellis search "cutover"
trellis related billing             # arcs sharing links, people, or systems
trellis priority billing on         # flag as focus; floats to the top of `list`
trellis pin billing on              # pin an arc/root into pinned.md (loads every session)
trellis review                      # decision inbox: arcs flagged for a look
trellis doctor                      # report drift between vault and index
```

Run `trellis help` for the full command list.

## Agents (MCP)

```sh
trellis mcp
```

starts a stdio MCP server that exposes the same operations as tools (`trellis_arc`, `trellis_root`, `trellis_overview`, `trellis_search`, `trellis_capture`, `trellis_append_log`, `trellis_add_task`, `trellis_pin`, and more). Register it with any MCP client so an agent can rehydrate an arc before working and write its findings back after.

## Vault layout

```
arcs/<area>-<slug>.md   durable work: frontmatter + ## Context / ## Tasks / ## Log
roots/<slug>.md         durable reference/context: no lifecycle (## Context / ## Log); may nest
artifacts/<slug>.md     long-form docs (plans, RFCs), linked from arcs
daily/, inbox/          append-only activity log and unrouted captures
people/, systems/       graph nodes referenced via [[links]]
pinned.md               derived digest of pinned arcs/roots, imported into ~/.claude/CLAUDE.md
.trellis/index.db       derived SQLite index (safe to delete; rebuild with reindex)
```

Arc frontmatter: `title`, `status` (`active` | `waiting` | `paused` | `done` | `dropped`), `tags`, `sources`, `created`, `updated`, `priority`, `needs_review`, `synopsis` (one-line gist), `flag_note` (why review was flagged), `pinned`. Roots carry only `title`, `tags`, `created`, `updated`, `synopsis`, `pinned`. Tasks in `## Tasks` support inline `@due(YYYY-MM-DD)`, `@waiting(who)`, `@blocked`, `@paused`.

## Development

`rake` runs the tests. Each test points `TRELLIS_VAULT` at a temporary directory, so the real vault is never touched. `CLAUDE.md` documents the architecture and the design invariants that keep the two interfaces in sync.
