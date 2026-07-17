require "date"
require "yaml"
require "json"

module Trellis
  # Write path — all mutations produce Markdown, then the caller reindexes.
  # No fetching, no LLM: agents supply already-enriched content.
  module Store
    module_function

    def slugify(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60]
    end

    # Create arcs/<area>-<slug>.md from a template. Returns the Pathname.
    def new_arc(title:, area: nil, tags: [], status: "active")
      base = slugify(title)
      slug = area ? "#{slugify(area)}-#{base}" : base
      Config.arcs_dir.mkpath
      path = Config.arcs_dir.join("#{slug}.md")
      raise "arc already exists: #{slug}" if path.exist?

      today = Date.today.to_s
      fm = {
        "title" => title, "status" => status, "tags" => Array(tags),
        "sources" => [], "created" => today, "updated" => today
      }
      path.write(<<~MD)
        ---
        #{YAML.dump(fm).delete_prefix("---\n").strip}
        ---

        ## Context


        ## Tasks


        ## Log
      MD
      path
    end

    # Create roots/[<area>/]<slug>.md — a non-lifecycle reference node: no status,
    # no ## Tasks. area becomes an organizing subfolder. kind is the optional
    # user-driven facet (system|person|principle|…). Returns the Pathname.
    def new_root(title:, area: nil, tags: [], kind: nil)
      slug = slugify(title)
      dir = area ? Config.roots_dir.join(slugify(area)) : Config.roots_dir
      dir.mkpath
      path = dir.join("#{slug}.md")
      raise "root already exists: #{area ? "#{slugify(area)}/" : ''}#{slug}" if path.exist?

      today = Date.today.to_s
      fm = { "title" => title }
      fm["kind"] = kind.to_s.strip unless kind.to_s.strip.empty?
      fm.merge!("tags" => Array(tags), "created" => today, "updated" => today)
      path.write(<<~MD)
        ---
        #{YAML.dump(fm).delete_prefix("---\n").strip}
        ---

        ## Context


        ## Log
      MD
      path
    end

    # Capture: route to an arc's log, a root's log, or the inbox. Always logs to daily.
    def capture(text, arc: nil, root: nil)
      if arc
        slug = append_log(slug: arc, text: text)
        daily_line("#{slug}: #{text}")
        { routed: slug }
      elsif root
        slug = append_log(slug: root, text: text, kind: "root")
        daily_line("#{slug}: #{text}")
        { routed: slug }
      else
        inbox_write(text)
        daily_line("inbox: #{text}")
        { routed: "inbox" }
      end
    end

    # Append a line under today's date block in ## Log (creating the block if needed).
    def append_log(slug:, text:, date: Date.today.to_s, kind: "arc")
      path = node_path(slug, kind: kind)
      raw = path.read
      header = "### #{date}"
      entry  = "- #{text}\n"

      raw =
        if raw.include?(header)
          raw.sub(/(#{Regexp.escape(header)}\n)/) { "#{$1}#{entry}" }
        elsif raw =~ /^## Log\s*$\n/
          raw.sub(/^## Log\s*$\n/) { "#{$&}\n#{header}\n#{entry}" }
        else
          raw + "\n## Log\n\n#{header}\n#{entry}"
        end

      path.write(bump_updated(raw, date))
      Arc.slug_for(path)
    end

    # Append a new open task under ## Tasks.
    def add_task(slug:, text:)
      path = arc_path(slug)
      raw = path.read
      line = "- [ ] #{text}\n"
      raw =
        if raw =~ /^## Tasks\s*$\n/
          raw.sub(/^## Tasks\s*$\n/) { "#{$&}#{line}" }
        else
          raw + "\n## Tasks\n#{line}"
        end
      path.write(bump_updated(raw))
      path.basename(".md").to_s
    end

    # Flag (on: true) or unflag (on: false) an arc as a priority. Priority is binary:
    # flagged arcs are the focus set and sort to the top of `list`.
    # Does NOT bump `updated` — priority is a triage lens, orthogonal to last-worked-on recency.
    def set_priority(slug:, on:)
      path = arc_path(slug)
      raw = path.read
      raw =
        if raw =~ /^priority:.*$/
          on ? raw.sub(/^priority:.*$/, "priority: true") : raw.sub(/^priority:.*$\n/, "")
        elsif on && raw =~ /^status:.*$/
          raw.sub(/^status:.*$/) { "#{$&}\npriority: true" }
        else
          raw
        end

      path.write(raw)
      { slug: path.basename(".md").to_s, priority: on }
    end

    # Flag (on: true) or unflag (on: false) an arc as needing review. Set by the
    # check-in agent when it finds a meaningful fresh signal; the human clears it
    # after looking. Orthogonal to status (a done arc can still need review — "reopen?")
    # and, like priority, does NOT bump `updated` — the accompanying log entry does.
    # note (optional): a short reason, stored as `flag_note` and surfaced by `overview`
    # / `review`. Set alongside the flag; cleared when the flag is cleared.
    def set_review(slug:, on:, note: nil)
      path = arc_path(slug)
      raw = path.read
      raw =
        if raw =~ /^needs_review:.*$/
          on ? raw.sub(/^needs_review:.*$/, "needs_review: true") : raw.sub(/^needs_review:.*$\n/, "")
        elsif on && raw =~ /^status:.*$/
          raw.sub(/^status:.*$/) { "#{$&}\nneeds_review: true" }
        else
          raw
        end

      path.write(raw)
      if on
        set_frontmatter(slug: slug, key: "flag_note", value: note) unless note.to_s.strip.empty?
      else
        set_frontmatter(slug: slug, key: "flag_note", value: "") # resolved → drop the reason
      end
      { slug: path.basename(".md").to_s, review: on }
    end

    # Set (or clear) a scalar string frontmatter key — the generic path for
    # descriptive fields like `synopsis` and `flag_note`. An empty/nil value strips
    # the key. The value is JSON-encoded (valid YAML) so multi-word / special-char
    # strings round-trip safely. New keys insert directly after `title:` (the anchor).
    # Like priority/review, does NOT bump `updated` — these describe, they aren't work.
    # Pin/unpin an arc or root. Binary like priority; anchors the new key after
    # `title:` so it works for roots too (which have no `status:` line). Pinned
    # entities render into pinned.md. Does not bump `updated`.
    def set_pinned(slug:, on:, kind: "arc")
      path = node_path(slug, kind: kind)
      raw = path.read
      raw =
        if raw =~ /^pinned:.*$/
          on ? raw.sub(/^pinned:.*$/, "pinned: true") : raw.sub(/^pinned:.*$\n/, "")
        elsif on && raw =~ /^title:.*$/
          raw.sub(/^title:.*$/) { "#{$&}\npinned: true" }
        else
          raw
        end
      path.write(raw)
      { slug: Arc.slug_for(path), pinned: on }
    end

    def set_frontmatter(slug:, key:, value:, kind: "arc")
      path = node_path(slug, kind: kind)
      raw = path.read
      clean = value.to_s.strip
      line = clean.empty? ? nil : "#{key}: #{clean.to_json}"
      pat = /^#{Regexp.escape(key)}:.*$/
      raw =
        if raw =~ pat
          line ? raw.sub(pat, line) : raw.sub(/^#{Regexp.escape(key)}:.*$\n/, "")
        elsif line && raw =~ /^title:.*$/
          raw.sub(/^title:.*$/) { "#{$&}\n#{line}" }
        else
          raw
        end
      path.write(raw)
      path.basename(".md").to_s
    end

    # ---- pinned.md (derived, always-loaded context) -----------------------

    # Rewrite <vault>/pinned.md from the pinned entities. Derived like the index:
    # delete it, re-run, get the same file. Enforces a hard line budget so it stays
    # a tight session-load digest; overflow truncates with a visible marker. When
    # content exists, ensures the ~/.claude/CLAUDE.md import (never *creates* that
    # file here — only `init` does, via ensure_pinned_import(create: true)).
    def regenerate_pinned(entities)
      path = Config.pinned_path
      Config.vault.mkpath
      if entities.empty?
        # A placeholder (not deletion) keeps a wired @import from dangling.
        path.write("# Pinned — trellis\n\n<!-- Nothing pinned. Use `trellis pin <slug>` to add. -->\n")
        ensure_pinned_import
        return { pinned: 0, truncated: 0 }
      end
      lines = [
        "# Pinned — trellis",
        "",
        "<!-- Generated by trellis from pinned arcs/roots. Edits are overwritten; use `trellis pin`. -->",
        "",
      ]
      shown = 0
      entities.each do |e|
        block = pinned_block(e)
        break if shown.positive? && (lines.length + block.length + 1) > Config.pinned_budget
        lines.concat(block) << ""
        shown += 1
      end
      remaining = entities.length - shown
      lines << "_+#{remaining} more pinned — run `trellis overview`_" if remaining.positive?
      Config.vault.mkpath
      path.write(lines.join("\n").rstrip + "\n")
      ensure_pinned_import
      { pinned: shown, truncated: remaining }
    end

    # One pinned entity → a short block: heading + synopsis + up to 2 Context lines.
    def pinned_block(row)
      head = row["kind"] == "root" ? "[root]" : "[#{row['status']}]"
      out = ["## #{row['title']}  #{head}"]
      syn = row["synopsis"].to_s.strip
      out << syn unless syn.empty?
      ctx = Arc.new(row["path"]).context.each_line.map(&:chomp).reject(&:empty?).first(2)
      out.concat(ctx)
      out
    end

    # Idempotently ensure ~/.claude/CLAUDE.md imports pinned.md. Additive only —
    # never rewrites or removes existing content. With create: false (the reindex/pin
    # path) it no-ops when the file is absent, so trellis never conjures a global
    # config as a side effect; `init` passes create: true to establish it.
    def ensure_pinned_import(create: false)
      target = Config.claude_md
      return { wired: false } unless create || target.exist?
      line = Config.pinned_import_line
      body = target.exist? ? target.read : ""
      return { wired: false } if body.include?(line)
      target.dirname.mkpath
      body += "\n" unless body.empty? || body.end_with?("\n")
      body += "#{line}\n"
      target.write(body)
      { wired: true }
    end

    def bump_updated(raw, date = Date.today.to_s)
      if raw =~ /^updated:.*$/
        raw.sub(/^updated:.*$/, "updated: #{date}")
      else
        raw
      end
    end

    def inbox_write(text, date: Date.today.to_s, time: Time.now.strftime("%H:%M"))
      Config.inbox_dir.mkpath
      f = Config.inbox_dir.join("#{date}.md")
      f.write("# Inbox — #{date}\n") unless f.exist?
      File.write(f, "\n- [#{time}] #{text}", mode: "a")
    end

    def daily_line(text, date: Date.today.to_s, time: Time.now.strftime("%H:%M"))
      Config.daily_dir.mkpath
      f = Config.daily_dir.join("#{date}.md")
      f.write("# #{date}\n") unless f.exist?
      File.write(f, "\n- [#{time}] #{text}", mode: "a")
    end

    # Resolve a slug or unique prefix to an existing node file (filesystem-only, no
    # index), scoped to a kind. Roots may be nested, so their glob recurses.
    def node_path(slug, kind: "arc")
      dir = kind == "root" ? Config.roots_dir : Config.arcs_dir
      exact = dir.join("#{slug}.md")
      return exact if exact.exist?
      hits = dir.glob(kind == "root" ? "**/#{slug}*.md" : "#{slug}*.md")
      raise "no #{kind} matches #{slug.inspect}" if hits.empty?
      raise "#{slug.inspect} is ambiguous: #{hits.map { |h| h.basename('.md') }.join(', ')}" if hits.length > 1
      hits.first
    end

    def arc_path(slug) = node_path(slug, kind: "arc")
  end
end
