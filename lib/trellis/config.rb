require "pathname"

module Trellis
  # Resolves where the vault (Markdown truth) lives. Override with TRELLIS_VAULT.
  module Config
    module_function

    def vault
      Pathname.new(ENV.fetch("TRELLIS_VAULT", File.expand_path("~/trellis")))
    end

    def arcs_dir   = vault.join("arcs")
    def roots_dir  = vault.join("roots")
    def daily_dir  = vault.join("daily")
    def inbox_dir  = vault.join("inbox")
    def artifacts_dir = vault.join("artifacts")
    def db_path    = vault.join(".trellis", "index.db")

    # Always-loaded context: a derived Markdown digest of pinned entities, imported
    # into ~/.claude/CLAUDE.md so it loads every session. All three are ENV-overridable
    # so tests never touch the real global config.
    def pinned_path = vault.join("pinned.md")
    def pinned_budget = Integer(ENV.fetch("TRELLIS_PINNED_BUDGET", "100"))
    def claude_md = Pathname.new(ENV.fetch("TRELLIS_CLAUDE_MD", File.expand_path("~/.claude/CLAUDE.md")))
    def pinned_import_line = "@#{ENV.fetch('TRELLIS_PINNED_IMPORT', '~/trellis/pinned.md')}"

    # Node-type dirs = the graph vocabulary. Arcs link to these; doctor checks they resolve.
    # Systems and people are no longer structural dirs — they're roots carrying a
    # user-driven `kind:` (system|person|…), a facet rather than a folder.
    def node_dirs = { "arcs" => arcs_dir, "roots" => roots_dir, "artifacts" => artifacts_dir }
  end
end
