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
    def pinned_import_line = "@#{ENV.fetch('TRELLIS_PINNED_IMPORT', pinned_path.to_s)}"

    # Files backing a vault-relative slug, any extension. A linked artifact may be an
    # .html mockup or a .pdf, so existence can't assume Markdown.
    def node_files(rel)
      md = vault.join("#{rel}.md")
      return [md] if md.file?
      dir = vault.join(rel).dirname
      return [] unless dir.directory?
      stem = File.basename(rel.to_s)
      dir.children.select { |f| f.file? && !f.basename.to_s.start_with?(".") && f.basename(".*").to_s == stem }.sort
    end

    # Non-Markdown artifacts (mockups, decks, PDFs). Real link targets — named, listed,
    # searchable by name — but never parsed, so nothing here reads their bytes.
    def asset_files(dir = artifacts_dir)
      return [] unless dir.directory?
      dir.glob("**/*").select { |f| f.file? && f.extname != ".md" && !hidden_within?(f, dir) }.sort
    end

    def hidden_within?(path, root)
      path.relative_path_from(root).each_filename.any? { |p| p.start_with?(".") }
    end

    # Node-type dirs = the graph vocabulary. Arcs link to these; doctor checks they resolve.
    # Systems and people are no longer structural dirs — they're roots carrying a
    # user-driven `kind:` (system|person|…), a facet rather than a folder.
    def node_dirs = { "arcs" => arcs_dir, "roots" => roots_dir, "artifacts" => artifacts_dir }
  end
end
