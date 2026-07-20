require "thor"

module Trellis
  class CLI < Thor
    def self.exit_on_failure? = true

    map "new" => :create
    map "add-task" => :add_task
    map "root" => :root_node

    desc "reindex", "Rebuild the index from the Markdown vault"
    def reindex
      c = index.reindex_all
      Store.regenerate_pinned(index.pinned_entities)
      say "reindexed → #{c[:arcs]} arcs, #{c[:roots]} roots, #{c[:artifacts]} artifacts, #{c[:open_tasks]} open tasks, #{c[:edges]} edges"
    end

    BIN_PATH = File.expand_path("../../bin/trellis", __dir__)

    desc "init", "Create vault dirs, build the index, git-init the vault, and wire pinned.md into ~/.claude/CLAUDE.md"
    def init
      Config.node_dirs.each_value(&:mkpath)
      [Config.daily_dir, Config.inbox_dir].each(&:mkpath)
      c = index.reindex_all
      Store.regenerate_pinned(index.pinned_entities)
      wired = Store.ensure_pinned_import(create: true)
      say "vault ready at #{Config.vault} — #{c[:arcs]} arcs, #{c[:roots]} roots indexed"
      say(wired[:wired] ? "wired '#{Config.pinned_import_line}' into #{Config.claude_md}" : "pinned.md import already present in #{Config.claude_md}")

      gitignore = Config.vault.join(".gitignore")
      unless gitignore.exist? && gitignore.read.include?(".trellis/")
        gitignore.write("#{gitignore.exist? ? "#{gitignore.read.chomp}\n" : ''}.trellis/\n")
        say "added .trellis/ to #{gitignore}"
      end

      if Git.repo?(Config.vault.to_s)
        say "vault already a git repo"
      else
        Git.init(Config.vault.to_s)
        Git.commit("init: vault")
        say "git-initialized vault at #{Config.vault}"
      end

      if File.exist?(BIN_PATH) && !File.executable?(BIN_PATH)
        File.chmod(File.stat(BIN_PATH).mode | 0o111, BIN_PATH)
        say "made #{BIN_PATH} executable"
      end

      say ""
      say "To run `trellis` from anywhere, symlink it onto your PATH, e.g.:", :yellow
      say "  ln -s #{BIN_PATH} ~/.local/bin/trellis"
      say "(swap in /usr/local/bin, or wherever else is already on your PATH)"
    end

    desc "pin ENTITY [on|off]", "Pin an arc or root into pinned.md (always-loaded session context), or 'off' to unpin. Pin sparingly — pinned.md has a hard size budget."
    def pin(entity, state = "on")
      slug = resolve!(entity, kind: nil)
      kind = index.arc(slug)["kind"] == "root" ? "root" : "arc"
      on = !(state.to_s =~ /\A(off|none|clear|no|false|0|-)\z/i)
      Store.set_pinned(slug: slug, on: on, kind: kind)
      index.index_arc(Arc.new(Store.node_path(slug, kind: kind)))
      res = Store.regenerate_pinned(index.pinned_entities)
      Git.commit("pin(#{slug}): #{on ? 'on' : 'off'}")
      say "#{slug} → #{on ? '📌 pinned' : 'not pinned'}"
      say "pinned.md: #{res[:pinned]} shown#{res[:truncated].positive? ? ", +#{res[:truncated]} truncated" : ''}", :white
    rescue RuntimeError => e
      abort e.message
    end

    desc "new TITLE", "Create a new arc (or a root with --kind roots)"
    method_option :area, aliases: "-a", desc: "Area: filename prefix (arcs) or organizing subfolder (roots)"
    method_option :tags, type: :array, default: [], desc: "Tags"
    method_option :kind, aliases: "-k", default: "arc", desc: "Node kind: arc (default) or roots"
    def create(*title_words)
      title = title_words.join(" ")
      abort "title required" if title.empty?
      tags = Array(options[:tags]).flat_map { |t| t.split(",") }.map(&:strip).reject(&:empty?)
      if root_kind?(options[:kind])
        path = Store.new_root(title: title, area: options[:area], tags: tags)
        slug = Arc.slug_for(path)
        index.index_arc(Arc.new(path))
        Git.commit("root: #{slug}")
        say "created root #{slug} → #{path}"
      else
        path = Store.new_arc(title: title, area: options[:area], tags: tags)
        index.index_arc(Arc.new(path))
        Git.commit("arc: #{path.basename('.md')}")
        say "created #{path.basename('.md')} → #{path}"
      end
    end

    desc "capture TEXT", "Capture a note into an arc's log, a root's log, or the inbox"
    method_option :arc, aliases: "-c", desc: "Arc slug (or prefix) to route to"
    method_option :root, aliases: "-r", desc: "Root slug (or prefix) to route to"
    def capture(*words)
      text = words.join(" ")
      abort "text required" if text.empty?
      abort "pass --arc or --root, not both" if options[:arc] && options[:root]
      if options[:root]
        slug = resolve!(options[:root], kind: "root")
        result = Store.capture(text, root: slug)
        index.index_arc(Arc.new(Store.node_path(slug, kind: "root")))
      elsif options[:arc]
        slug = resolve!(options[:arc], kind: "arc")
        result = Store.capture(text, arc: slug)
        index.index_arc(Arc.new(Store.node_path(slug, kind: "arc")))
      else
        result = Store.capture(text)
      end
      Git.commit("capture(#{result[:routed]}): #{Git.summarize(text)}")
      say "captured → #{result[:routed]}"
    end

    desc "add-task ARC TEXT", "Add an open task to an arc"
    def add_task(arc, *words)
      slug = resolve!(arc)
      text = words.join(" ")
      Store.add_task(slug: slug, text: text)
      index.index_arc(Arc.new(Store.arc_path(slug)))
      Git.commit("task(#{slug}): #{Git.summarize(text)}")
      say "added task to #{slug}"
    end

    desc "log SLUG", "Print the full ## Log history for an arc or root (all date blocks)"
    def log(query)
      slug = resolve!(query, kind: nil)
      full = Arc.new(index.arc(slug)["path"]).full_log
      say full.empty? ? "no log for #{slug}" : full
    end

    desc "compact ARC", "Consolidate: replace ## Context with new prose from STDIN and/or drop old log blocks (--keep N). Git keeps the dropped raw."
    method_option :keep, type: :numeric, desc: "Keep only the newest N log date blocks"
    def compact(arc)
      slug = resolve!(arc)
      ctx = $stdin.stat.pipe? ? $stdin.read : nil
      ctx = nil if ctx && ctx.strip.empty?
      abort "pipe new Context via STDIN and/or pass --keep N" if ctx.nil? && options[:keep].nil?
      Store.compact(slug: slug, context: ctx, keep_log_blocks: options[:keep])
      index.index_arc(Arc.new(Store.arc_path(slug)))
      Git.commit("compact(#{slug})")
      say "compacted #{slug}"
    rescue ArgumentError => e
      abort e.message
    end

    desc "priority ARC [on|off]", "Flag an arc as a priority (focus), or 'off' to unflag. Default: on."
    def priority(arc, state = "on")
      slug = resolve!(arc)
      on = !(state.to_s =~ /\A(off|none|clear|no|false|0|-)\z/i)
      Store.set_priority(slug: slug, on: on)
      index.index_arc(Arc.new(Store.arc_path(slug)))
      Git.commit("priority(#{slug}): #{on ? 'on' : 'off'}")
      say "#{slug} → #{on ? '⭐ priority' : 'not priority'}"
    rescue RuntimeError => e
      abort e.message
    end

    desc "review [SLUG] [on|off]", "No arg: list the decision inbox (arcs needing review + latest log). With a slug: flag/unflag. The check-in agent flags on a fresh signal; clear with 'off' once you've looked."
    method_option :note, aliases: "-n", desc: "Short reason (flag_note) shown in overview/review; set when flagging on"
    def review(arc = nil, state = "on")
      return review_inbox if arc.nil?
      slug = resolve!(arc)
      on = !(state.to_s =~ /\A(off|none|clear|no|false|0|-)\z/i)
      Store.set_review(slug: slug, on: on, note: options[:note])
      index.index_arc(Arc.new(Store.arc_path(slug)))
      Git.commit("review(#{slug}): #{on ? 'on' : 'off'}")
      say "#{slug} → #{on ? '🔎 needs review' : 'reviewed'}"
    rescue RuntimeError => e
      abort e.message
    end

    desc "list", "List arcs: priorities first, then by status (active>waiting>paused>done), then recency"
    method_option :status, aliases: "-s", desc: "Filter by status (active|waiting|paused|done|dropped)"
    def list
      rows = index.list_arcs(status: options[:status])
      if rows.empty?
        say "no arcs"
        return
      end
      rows.each do |r|
        say "  #{review_tag(r['needs_review'])} #{priority_tag(r['priority'])}  #{r['slug']}  [#{r['status']}]  — #{r['title']}"
      end
    end

    desc "overview", "Quick digest: each arc's synopsis + status (review reason for flagged ones), same order as list"
    def overview
      rows, total = index.overview
      if rows.empty?
        say "no arcs"
        return
      end
      rows.each do |r|
        gist = r["synopsis"].to_s.strip.empty? ? r["title"] : r["synopsis"]
        say "  #{review_tag(r['needs_review'])} #{priority_tag(r['priority'])}  #{gist}  [#{r['status']}]  ·  #{r['slug']}"
        fn = r["flag_note"].to_s.strip
        say "        🔎 #{fn}", :white if r["needs_review"].to_s == "true" && !fn.empty?
      end
      hidden = total - rows.length
      say "\n+#{hidden} more — use `trellis list`", :white if hidden.positive?
    end

    desc "roots", "List roots (reference nodes), optionally filtered by --kind (system|person|…)"
    method_option :kind, aliases: "-k", desc: "Filter by kind facet (system|person|principle|…)"
    def roots
      rows = index.roots(kind: options[:kind])
      if rows.empty?
        say options[:kind] ? "no roots with kind '#{options[:kind]}'" : "no roots"
        return
      end
      rows.each do |r|
        k = r["entity_kind"].to_s.strip
        say "  #{r['slug']}#{k.empty? ? '' : "  [#{k}]"}  — #{r['title']}"
      end
    end

    desc "arc SLUG", "Rehydrate an arc: context, open tasks, recent log, links"
    def arc(query)
      slug = resolve!(query)
      a = index.arc(slug)
      tasks = index.tasks_for(slug).reject { |t| t["done"] == 1 }
      arcfile = Arc.new(a["path"])
      log = arcfile.latest_log

      say ""
      say "━━ #{slug}  [#{a['status']}]", :cyan
      say a["title"], :bold
      meta = []
      meta << "🔎 needs review" if a["needs_review"].to_s == "true"
      meta << "⭐ priority" if a["priority"].to_s == "true"
      meta << "kind: #{a['entity_kind']}" unless a["entity_kind"].to_s.strip.empty?
      meta << "tags: #{JSON.parse(a['tags']).join(', ')}" unless JSON.parse(a["tags"]).empty?
      meta << "updated #{a['updated']}" unless a["updated"].to_s.empty?
      say meta.join("   ·   "), :white unless meta.empty?

      unless a["context"].to_s.strip.empty?
        say "\nContext", :yellow
        a["context"].each_line { |l| say "  #{l.chomp}" }
      end

      say "\nOpen tasks (#{tasks.length})", :yellow
      tasks.each { |t| say "  #{task_glyph(t['state'])} #{t['text']}" }
      say "  (none)" if tasks.empty?

      if log
        say "\nRecent log — #{log[:date]}", :yellow
        log[:entries].each_line { |l| say "  #{l.chomp}" }
        say "  …log block truncated — full history via `trellis log #{slug}`", :white if log[:truncated]
      end

      srcs = index.sources_for(slug)
      unless srcs.empty?
        say "\nSources", :yellow
        srcs.each { |s| say "  #{s['kind']} #{s['ref']}" }
      end

      links = arcfile.links
      say "\nLinks → #{links.map { |l| l[:target] }.join(', ')}" unless links.empty?
      back = index.backlinks("arcs/#{slug}") + index.backlinks(slug)
      say "Backlinks ← #{back.uniq.join(', ')}" unless back.empty?
      say ""
    end

    desc "root SLUG", "Rehydrate a root: context, recent log, links, backlinks (reference node, no tasks)"
    def root_node(query)
      slug = resolve!(query, kind: "root")
      a = index.arc(slug)
      file = Arc.new(a["path"])
      log = file.latest_log

      k = a["entity_kind"].to_s.strip
      say ""
      say "━━ #{slug}  [root#{k.empty? ? '' : " · #{k}"}]", :cyan
      say a["title"], :bold
      meta = []
      meta << a["synopsis"] unless a["synopsis"].to_s.strip.empty?
      meta << "tags: #{JSON.parse(a['tags']).join(', ')}" unless JSON.parse(a["tags"]).empty?
      meta << "updated #{a['updated']}" unless a["updated"].to_s.empty?
      say meta.join("   ·   "), :white unless meta.empty?

      unless a["context"].to_s.strip.empty?
        say "\nContext", :yellow
        a["context"].each_line { |l| say "  #{l.chomp}" }
      end

      if log
        say "\nRecent log — #{log[:date]}", :yellow
        log[:entries].each_line { |l| say "  #{l.chomp}" }
        say "  …log block truncated — full history via `trellis log #{slug}`", :white if log[:truncated]
      end

      links = file.links
      say "\nLinks → #{links.map { |l| l[:target] }.join(', ')}" unless links.empty?
      back = (index.backlinks("roots/#{slug}") + index.backlinks(slug)).uniq
      say "Backlinks ← #{back.join(', ')}" unless back.empty?
      say ""
    end

    desc "tasks", "List open tasks across active arcs, grouped by state"
    method_option :waiting, type: :boolean, desc: "Only waiting_for tasks"
    method_option :due, type: :boolean, desc: "Only tasks with a due date"
    method_option :arc, desc: "Filter to one arc (any status)"
    method_option :all, type: :boolean, desc: "Include tasks from non-active arcs (paused, waiting, etc.)"
    def tasks
      state = options[:waiting] ? "waiting" : nil
      arc = options[:arc] ? resolve!(options[:arc]) : nil
      rows = index.open_tasks(state: state, arc: arc, all: options[:all])
      rows = rows.select { |r| !r["due"].to_s.empty? } if options[:due]
      if rows.empty?
        say "no open tasks"
      else
        rows.group_by { |r| r["state"] }.each do |st, group|
          say "\n#{st} (#{group.length})", :yellow
          group.each do |t|
            extra = []
            extra << "due #{t['due']}" unless t["due"].to_s.empty?
            extra << "waiting: #{t['waiting_on']}" unless t["waiting_on"].to_s.empty?
            suffix = extra.empty? ? "" : "  [#{extra.join(', ')}]"
            say "  #{task_glyph(st)} #{t['text']}#{suffix}", nil
            say "      ↳ #{t['arc']}", :white
          end
        end
      end
      unless options[:all] || arc
        hidden = index.hidden_task_count
        say "\n+#{hidden} task#{'s' unless hidden == 1} in non-active arcs — use --all to show", :white if hidden.positive?
      end
    end

    desc "related SLUG", "Arcs connected to this one via links or shared nodes"
    def related(query)
      slug = resolve!(query)
      rel = index.related(slug)
      if rel.empty?
        say "no related arcs"
        return
      end
      say "related to #{slug}:", :cyan
      rel.each { |s| a = index.arc(s); say "  #{s}#{a ? "  — #{a['title']}" : ''}" }
    end

    desc "search QUERY", "Full-text search across arcs + artifacts, ranked by relevance then recency (excludes done/dropped)"
    def search(*words)
      q = words.join(" ")
      rows = index.search(q)
      if rows.empty?
        say "no matches"
        return
      end
      rows.each do |r|
        ref = case r[:type]
              when "artifact" then "artifacts/#{r[:slug]}"
              when "root"     then "roots/#{r[:slug]}"
              else r[:slug]
              end
        label = r[:kind].to_s.strip.empty? ? r[:type] : "#{r[:type]} · #{r[:kind]}"
        say "  #{ref}  [#{label}] — #{r[:title]}"
        snip = r[:snip].to_s.gsub(/\s+/, " ").strip
        say "      ↳ #{snip}" unless snip.empty?
      end
    end

    desc "artifacts", "List artifacts (drafts/docs); shows which arcs link each"
    def artifacts
      files = Config.artifacts_dir.exist? ? Config.artifacts_dir.glob("**/*.md").sort : []
      if files.empty?
        say "no artifacts"
        return
      end
      files.each do |f|
        arc = Arc.new(f)
        back = index.backlinks("artifacts/#{arc.slug}")
        say "  #{arc.slug}  — #{arc.title}#{back.empty? ? '' : "  ← #{back.join(', ')}"}"
      end
    end

    desc "doctor", "Check for drift between the vault and the index"
    def doctor
      issues = []
      disk = Config.arcs_dir.glob("*.md").map { |f| f.basename(".md").to_s }.sort
      indexed = index.list_arcs.map { |r| r["slug"] }.sort
      (disk - indexed).each { |s| issues << ["missing-from-index", s] }
      (indexed - disk).each { |s| issues << ["indexed-but-no-file", s] }

      if Config.roots_dir.exist?
        disk_roots = Config.roots_dir.glob("**/*.md").map { |f| Arc.slug_for(f) }.sort
        idx_roots  = index.root_slugs.sort
        (disk_roots - idx_roots).each { |s| issues << ["missing-from-index", "roots/#{s}"] }
        (idx_roots - disk_roots).each { |s| issues << ["indexed-but-no-file", "roots/#{s}"] }
      end

      (Config.arcs_dir.glob("*.md") + (Config.roots_dir.exist? ? Config.roots_dir.glob("**/*.md") : [])).each do |f|
        a = Arc.new(f)
        issues << ["frontmatter-error", a.slug] if a.frontmatter["_frontmatter_error"]
      end

      index.all_edges.each do |e|
        next unless Config.node_dirs.key?(e["kind"])
        target_file = Config.vault.join("#{e['target']}.md")
        issues << ["dangling-link", "#{e['src']} → #{e['target']}"] unless target_file.exist?
      end

      if issues.empty?
        say "✓ no drift", :green
      else
        issues.each { |cat, tgt| say "⚠ #{cat}: #{tgt}", :yellow }
      end
    end

    desc "mcp", "Run the MCP server over stdio (for agents)"
    def mcp
      require_relative "mcp_server"
      Trellis::MCPServer.run
    end

    desc "version", "Print version"
    def version = say(Trellis::VERSION)

    private

    def index = @index ||= Index.new

    def review_inbox
      rows = index.review_arcs
      if rows.empty?
        say "nothing needs review", :green
        return
      end
      say "needs review (#{rows.length}):", :cyan
      rows.each do |r|
        say "  🔎 #{r['slug']}  [#{r['status']}]  — #{r['title']}"
        log = Arc.new(r["path"]).latest_log
        say "      ↳ #{log[:entries].lines.first&.chomp}", :white if log
      end
    end

    def resolve!(query, kind: "arc")
      index.resolve_slug(query, kind: kind)
    rescue Index::NotFound
      abort "no #{kind || 'node'} matches #{query.inspect}"
    rescue Index::Ambiguous => e
      abort "ambiguous: #{e.message}"
    end

    def root_kind?(kind) = %w[root roots].include?(kind.to_s.downcase)

    def task_glyph(state)
      { "open" => "○", "waiting" => "⏳", "blocked" => "⛔", "paused" => "⏸" }[state] || "○"
    end

    def priority_tag(p)
      p.to_s == "true" ? "⭐" : "·"
    end

    def review_tag(r)
      r.to_s == "true" ? "🔎" : "·"
    end
  end
end
