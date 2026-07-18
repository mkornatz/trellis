require "mcp"
require_relative "../trellis"

module Trellis
  # MCP stdio server — the interface agents use from any repo.
  # Read tools rehydrate context; write tools append MD then reindex. No LLM, no fetch.
  module MCPServer
    module_function

    def idx = @idx ||= Index.new
    def text(str) = MCP::Tool::Response.new([{ type: "text", text: str }])
    def reindex_node(slug, kind: "arc") = idx.index_arc(Arc.new(Store.node_path(slug, kind: kind)))
    def reindex(slug) = reindex_node(slug, kind: "arc")

    # Every tool's self.call runs its body through this. An uncaught exception
    # would otherwise cross the mcp gem's generic handler and reach the client as
    # a message-less "-32603 Internal error" — useless to a user or agent mid-task.
    # Known errors (bad/ambiguous slug, Store validation) return readable text.
    # Anything unanticipated still returns readable text *and* logs class + message
    # + backtrace to stderr, which Claude Desktop captures per-server
    # (~/Library/Logs/Claude/mcp-server-trellis.log) — so a real bug is diagnosable
    # from the log instead of invisible.
    def guard(tool_name)
      yield
    rescue Index::NotFound, Index::Ambiguous, RuntimeError => e
      text("error: #{e.message}")
    rescue StandardError => e
      warn "[trellis] #{tool_name} failed: #{e.class}: #{e.message}"
      (e.backtrace || []).first(10).each { |line| warn "[trellis]   #{line}" }
      text("error: #{e.class}: #{e.message}")
    end

    # ---- formatters (agents read Markdown) --------------------------------

    def arc_md(query)
      slug = idx.resolve_slug(query)
      a = idx.arc(slug)
      file = Arc.new(a["path"])
      open = idx.tasks_for(slug).reject { |t| t["done"] == 1 }
      out = +"# #{a['title']}  [#{a['status']}]\n"
      out << "needs review: 🔎\n" if a["needs_review"].to_s == "true"
      out << "priority: ⭐\n" if a["priority"].to_s == "true"
      tags = JSON.parse(a["tags"])
      out << "tags: #{tags.join(', ')}\n" unless tags.empty?
      out << "updated: #{a['updated']}\n"
      out << "\n## Context\n#{a['context']}\n" unless a["context"].to_s.strip.empty?
      out << "\n## Open tasks (#{open.length})\n"
      open.each do |t|
        extra = [t["due"] && "due #{t['due']}", t["waiting_on"] && "waiting: #{t['waiting_on']}"].compact
        out << "- [#{t['state']}] #{t['text']}#{extra.empty? ? '' : " (#{extra.join(', ')})"}\n"
      end
      if (log = file.latest_log)
        out << "\n## Recent log — #{log[:date]}\n#{log[:entries]}\n"
      end
      srcs = idx.sources_for(slug)
      out << "\n## Sources\n" + srcs.map { |s| "- #{s['kind']}: #{s['ref']}" }.join("\n") + "\n" unless srcs.empty?
      links = file.links
      out << "\n## Links\n" + links.map { |l| "- #{l[:target]}" }.join("\n") + "\n" unless links.empty?
      back = (idx.backlinks("arcs/#{slug}") + idx.backlinks(slug)).uniq
      out << "\n## Backlinks\n" + back.map { |s| "- #{s}" }.join("\n") + "\n" unless back.empty?
      out
    end

    def root_md(query)
      slug = idx.resolve_slug(query, kind: "root")
      a = idx.arc(slug)
      file = Arc.new(a["path"])
      k = a["entity_kind"].to_s.strip
      out = +"# #{a['title']}  [root#{k.empty? ? '' : " · #{k}"}]\n"
      out << "kind: #{k}\n" unless k.empty?
      out << "synopsis: #{a['synopsis']}\n" unless a["synopsis"].to_s.strip.empty?
      tags = JSON.parse(a["tags"])
      out << "tags: #{tags.join(', ')}\n" unless tags.empty?
      out << "updated: #{a['updated']}\n"
      out << "\n## Context\n#{a['context']}\n" unless a["context"].to_s.strip.empty?
      if (log = file.latest_log)
        out << "\n## Recent log — #{log[:date]}\n#{log[:entries]}\n"
      end
      links = file.links
      out << "\n## Links\n" + links.map { |l| "- #{l[:target]}" }.join("\n") + "\n" unless links.empty?
      back = (idx.backlinks("roots/#{slug}") + idx.backlinks(slug)).uniq
      out << "\n## Backlinks\n" + back.map { |s| "- #{s}" }.join("\n") + "\n" unless back.empty?
      out
    end

    def list_arcs_md(status)
      rows = idx.list_arcs(status: status)
      return "no arcs" if rows.empty?
      rows.map do |r|
        rev = r["needs_review"].to_s == "true" ? "🔎" : "·"
        pri = r["priority"].to_s == "true" ? "⭐" : "·"
        "- #{rev} #{pri} #{r['slug']}  [#{r['status']}]  — #{r['title']}"
      end.join("\n")
    end

    def overview_md
      rows, total = idx.overview
      return "no arcs" if rows.empty?
      out = rows.map do |r|
        gist = r["synopsis"].to_s.strip.empty? ? r["title"] : r["synopsis"]
        rev = r["needs_review"].to_s == "true" ? "🔎" : "·"
        pri = r["priority"].to_s == "true" ? "⭐" : "·"
        line = "- #{rev} #{pri} #{gist} [#{r['status']}] · #{r['slug']}"
        fn = r["flag_note"].to_s.strip
        line += "\n    ↳ review: #{fn}" if r["needs_review"].to_s == "true" && !fn.empty?
        line
      end.join("\n")
      hidden = total - rows.length
      out += "\n\n+#{hidden} more — use trellis_list_arcs" if hidden.positive?
      out
    end

    def tasks_md(state, arc, all = false)
      arc = idx.resolve_slug(arc) if arc
      rows = idx.open_tasks(state: state, arc: arc, all: all)
      return "no open tasks" if rows.empty?
      rows.group_by { |r| r["state"] }.map do |st, g|
        "## #{st} (#{g.length})\n" + g.map do |t|
          extra = [t["due"] && "due #{t['due']}", t["waiting_on"] && "waiting: #{t['waiting_on']}"].compact
          "- #{t['text']}#{extra.empty? ? '' : " (#{extra.join(', ')})"}  ↳ #{t['arc']}"
        end.join("\n")
      end.join("\n\n")
    end

    def related_md(query)
      slug = idx.resolve_slug(query)
      rel = idx.related(slug)
      return "no related arcs" if rel.empty?
      rel.map { |s| a = idx.arc(s); "- #{s}#{a ? " — #{a['title']}" : ''}" }.join("\n")
    end

    def search_md(query)
      rows = idx.search(query)
      return "no matches" if rows.empty?
      rows.map do |r|
        ref = r[:type] == "artifact" ? "artifacts/#{r[:slug]}" : r[:slug]
        label = r[:kind].to_s.strip.empty? ? r[:type] : "#{r[:type]} · #{r[:kind]}"
        "- #{ref} [#{label}] — #{r[:title]}"
      end.join("\n")
    end

    def roots_md(kind = nil)
      rows = idx.roots(kind: kind)
      return (kind ? "no roots with kind '#{kind}'" : "no roots") if rows.empty?
      rows.map do |r|
        k = r["entity_kind"].to_s.strip
        "- #{r['slug']}#{k.empty? ? '' : " [#{k}]"} — #{r['title']}"
      end.join("\n")
    end

    # ---- tools ------------------------------------------------------------

    class ListArcs < MCP::Tool
      tool_name "trellis_list_arcs"
      description "List arcs: priorities (⭐) first, then by status (active>waiting>paused>done>dropped), then most-recently-updated. Optionally filter by status."
      input_schema(properties: { status: { type: "string" } }, required: [])
      def self.call(status: nil, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.list_arcs_md(status)) }
      end
    end

    class Overview < MCP::Tool
      tool_name "trellis_overview"
      description "Quick digest of arcs for a glance: each arc's synopsis (or title) + status, and the review reason (flag_note) for arcs needing review. Same ordering as trellis_list_arcs, capped. Use to reorient at the start of a session."
      input_schema(properties: {}, required: [])
      def self.call(server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.overview_md) }
      end
    end

    class GetArc < MCP::Tool
      tool_name "trellis_arc"
      description "Rehydrate an arc by slug or unique prefix: context, open tasks, recent log, sources, links, backlinks. Call this before working on anything to reload full context."
      input_schema(properties: { slug: { type: "string" } }, required: ["slug"])
      def self.call(slug:, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.arc_md(slug)) }
      end
    end

    class Tasks < MCP::Tool
      tool_name "trellis_tasks"
      description "List open tasks grouped by state. Defaults to active arcs only (paused/waiting arcs = not on the plate now); pass all=true to include them. Optional state filter (open|waiting|blocked|paused) and arc filter (any status)."
      input_schema(properties: { state: { type: "string" }, arc: { type: "string" }, all: { type: "boolean" } }, required: [])
      def self.call(state: nil, arc: nil, all: false, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.tasks_md(state, arc, all)) }
      end
    end

    class Search < MCP::Tool
      tool_name "trellis_search"
      description "Full-text search across arcs. Returns matching arc slugs + titles."
      input_schema(properties: { query: { type: "string" } }, required: ["query"])
      def self.call(query:, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.search_md(query)) }
      end
    end

    class Related < MCP::Tool
      tool_name "trellis_related"
      description "Arcs connected to the given arc via links or shared nodes (people/systems)."
      input_schema(properties: { slug: { type: "string" } }, required: ["slug"])
      def self.call(slug:, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.related_md(slug)) }
      end
    end

    class Capture < MCP::Tool
      tool_name "trellis_capture"
      description "Capture a note. If arc (slug/prefix) is given, appends to that arc's log; if root is given, appends to that root's log; else drops in the inbox. Always logs to the daily file. Pass already-synthesized content."
      input_schema(properties: { text: { type: "string" }, arc: { type: "string" }, root: { type: "string" } }, required: ["text"])
      def self.call(text:, arc: nil, root: nil, server_context: nil)
        MCPServer.guard(tool_name) do
          if root
            slug = MCPServer.idx.resolve_slug(root, kind: "root")
            result = Store.capture(text, root: slug)
            MCPServer.reindex_node(slug, kind: "root")
          elsif arc
            slug = MCPServer.idx.resolve_slug(arc, kind: "arc")
            result = Store.capture(text, arc: slug)
            MCPServer.reindex_node(slug, kind: "arc")
          else
            result = Store.capture(text)
          end
          Git.commit("capture(#{result[:routed]}): #{Git.summarize(text)}")
          MCPServer.text("captured → #{result[:routed]}")
        end
      end
    end

    class AppendLog < MCP::Tool
      tool_name "trellis_append_log"
      description "Append a synthesized findings entry to an arc's log under today's date. Use to write back what you discovered while working an arc."
      input_schema(properties: { slug: { type: "string" }, text: { type: "string" } }, required: ["slug", "text"])
      def self.call(slug:, text:, server_context: nil)
        MCPServer.guard(tool_name) do
          s = MCPServer.idx.resolve_slug(slug)
          Store.append_log(slug: s, text: text)
          MCPServer.reindex(s)
          Git.commit("log(#{s}): #{Git.summarize(text)}")
          MCPServer.text("appended to #{s}")
        end
      end
    end

    class AddTask < MCP::Tool
      tool_name "trellis_add_task"
      description "Add an open task to an arc. Supports inline @due(YYYY-MM-DD), @waiting(who), @blocked in the text."
      input_schema(properties: { slug: { type: "string" }, text: { type: "string" } }, required: ["slug", "text"])
      def self.call(slug:, text:, server_context: nil)
        MCPServer.guard(tool_name) do
          s = MCPServer.idx.resolve_slug(slug)
          Store.add_task(slug: s, text: text)
          MCPServer.reindex(s)
          Git.commit("task(#{s}): #{Git.summarize(text)}")
          MCPServer.text("added task to #{s}")
        end
      end
    end

    class SetPriority < MCP::Tool
      tool_name "trellis_set_priority"
      description "Flag or unflag an arc as a priority. Priority is binary — flagged arcs are the focus set and sort to the top of the list. Pass on=false to unflag. Changes freely week to week."
      input_schema(properties: { slug: { type: "string" }, on: { type: "boolean" } }, required: ["slug"])
      def self.call(slug:, on: true, server_context: nil)
        MCPServer.guard(tool_name) do
          s = MCPServer.idx.resolve_slug(slug)
          Store.set_priority(slug: s, on: on)
          MCPServer.reindex(s)
          Git.commit("priority(#{s}): #{on ? 'on' : 'off'}")
          MCPServer.text("#{s} → #{on ? '⭐ priority' : 'not priority'}")
        end
      end
    end

    class SetReview < MCP::Tool
      tool_name "trellis_set_review"
      description "Flag an arc as needing review after finding a MEANINGFUL fresh signal — something that warrants a human decision: a resolved or new blocker, an external deadline, a changed requirement, a reason to reopen dormant (done/paused) work. NOT for benign or routine updates. First append_log the synthesized signal and a suggested action, then flag. Pass a short `note` (the reason) so it shows in the overview/decision inbox. Pass on=false to clear once reviewed. Never change the arc's status yourself — flag it and let the human decide."
      input_schema(properties: { slug: { type: "string" }, on: { type: "boolean" }, note: { type: "string" } }, required: ["slug"])
      def self.call(slug:, on: true, note: nil, server_context: nil)
        MCPServer.guard(tool_name) do
          s = MCPServer.idx.resolve_slug(slug)
          Store.set_review(slug: s, on: on, note: note)
          MCPServer.reindex(s)
          Git.commit("review(#{s}): #{on ? 'on' : 'off'}")
          MCPServer.text("#{s} → #{on ? '🔎 needs review' : 'reviewed'}")
        end
      end
    end

    class GetRoot < MCP::Tool
      tool_name "trellis_root"
      description "Rehydrate a root (durable reference node) by slug or unique prefix: context, recent log, links, backlinks. Roots accumulate reference material and have no tasks or lifecycle status."
      input_schema(properties: { slug: { type: "string" } }, required: ["slug"])
      def self.call(slug:, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.root_md(slug)) }
      end
    end

    class NewRoot < MCP::Tool
      tool_name "trellis_new_root"
      description "Create a root: a durable, non-lifecycle reference node (no status, no tasks) for context that accumulates over time (people, systems, finances, preferences, etc.). area becomes an organizing subfolder. kind is an optional user-driven facet (system|person|principle|…) for classifying and later filtering the node."
      input_schema(
        properties: { title: { type: "string" }, area: { type: "string" }, tags: { type: "array", items: { type: "string" } }, kind: { type: "string" } },
        required: ["title"]
      )
      def self.call(title:, area: nil, tags: [], kind: nil, server_context: nil)
        MCPServer.guard(tool_name) do
          path = Store.new_root(title: title, area: area, tags: tags, kind: kind)
          slug = Arc.slug_for(path)
          MCPServer.reindex_node(slug, kind: "root")
          Git.commit("root: #{slug}")
          MCPServer.text("created root #{slug}")
        end
      end
    end

    class Roots < MCP::Tool
      tool_name "trellis_roots"
      description "List roots (durable reference nodes: people, systems, principles, and other non-lifecycle context), optionally filtered by kind (system|person|principle|…). Use to enumerate reference nodes of a given kind."
      input_schema(properties: { kind: { type: "string" } }, required: [])
      def self.call(kind: nil, server_context: nil)
        MCPServer.guard(tool_name) { MCPServer.text(MCPServer.roots_md(kind)) }
      end
    end

    class SetPinned < MCP::Tool
      tool_name "trellis_pin"
      description "Pin or unpin an arc or root so it renders into pinned.md — context loaded into every Claude Code session. Pin SPARINGLY: pinned.md has a hard size budget and loads in full regardless of relevance. Pass on=false to unpin."
      input_schema(properties: { slug: { type: "string" }, on: { type: "boolean" } }, required: ["slug"])
      def self.call(slug:, on: true, server_context: nil)
        MCPServer.guard(tool_name) do
          s = MCPServer.idx.resolve_slug(slug)
          kind = MCPServer.idx.arc(s)["kind"] == "root" ? "root" : "arc"
          Store.set_pinned(slug: s, on: on, kind: kind)
          MCPServer.reindex_node(s, kind: kind)
          Store.regenerate_pinned(MCPServer.idx.pinned_entities)
          Git.commit("pin(#{s}): #{on ? 'on' : 'off'}")
          MCPServer.text("#{s} → #{on ? '📌 pinned' : 'not pinned'}")
        end
      end
    end

    class NewArc < MCP::Tool
      tool_name "trellis_new_arc"
      description "Create a new arc. area prefixes the filename (e.g. infra, research)."
      input_schema(
        properties: { title: { type: "string" }, area: { type: "string" }, tags: { type: "array", items: { type: "string" } } },
        required: ["title"]
      )
      def self.call(title:, area: nil, tags: [], server_context: nil)
        MCPServer.guard(tool_name) do
          path = Store.new_arc(title: title, area: area, tags: tags)
          slug = path.basename(".md").to_s
          MCPServer.reindex(slug)
          Git.commit("arc: #{slug}")
          MCPServer.text("created #{slug}")
        end
      end
    end

    TOOLS = [ListArcs, Overview, GetArc, GetRoot, Roots, Tasks, Search, Related, Capture, AppendLog, AddTask, NewArc, NewRoot, SetPriority, SetReview, SetPinned].freeze

    def run
      server = MCP::Server.new(name: "trellis", version: Trellis::VERSION, tools: TOOLS)
      MCP::Server::Transports::StdioTransport.new(server).open
    end
  end
end
