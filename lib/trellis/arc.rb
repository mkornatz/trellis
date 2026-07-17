require "yaml"
require "pathname"

module Trellis
  # Parses one arc Markdown file into structured data. Read-only; the file is truth.
  class Arc
    SECTION_RE = /^##\s+(.+?)\s*$/
    TASK_RE    = /^\s*-\s*\[( |x|X)\]\s+(.*)$/
    LINK_RE    = /\[\[([^\]]+)\]\]/
    DUE_RE     = /@due\((\d{4}-\d{2}-\d{2})\)/
    WAIT_RE    = /@waiting\(([^)]*)\)/

    # Priority is binary: an arc is either a focus ("priority") or it isn't.
    # These frontmatter values all read as flagged; anything else (incl. absent) is not.
    # `h/m/l/high/…` are accepted so pre-binary arcs stay flagged until re-saved.
    PRIORITY_TRUTHY = %w[true yes 1 y on h m l high med medium low].freeze

    attr_reader :slug, :path, :frontmatter, :body, :sections

    # Is this arc flagged as a priority? Accepts YAML booleans and legacy string values.
    def self.priority?(value)
      case value
      when true  then true
      when false, nil then false
      else PRIORITY_TRUTHY.include?(value.to_s.strip.downcase)
      end
    end

    def initialize(path)
      @path = Pathname.new(path)
      @slug = self.class.slug_for(@path)
      raw = @path.read
      @frontmatter, @body = split_frontmatter(raw)
      @sections = split_sections(@body)
    end

    # Slug = path relative to its node dir, minus .md — so a nested root
    # (roots/finances/accounts) keeps a unique, link-addressable slug. Flat files
    # (all arcs) reduce to the bare basename, so nothing about arcs changes.
    def self.slug_for(path)
      path = Pathname.new(path)
      Config.node_dirs.each_value do |dir|
        rel = relative_within(path, dir)
        return rel.sub_ext("").to_s if rel
      end
      path.basename(".md").to_s
    end

    # `rel` of path within dir, or nil if path isn't under dir. Lexical only.
    def self.relative_within(path, dir)
      return nil unless dir
      rel = Pathname.new(path).expand_path.relative_path_from(Pathname.new(dir).expand_path)
      rel.to_s.start_with?("..") ? nil : rel
    rescue ArgumentError
      nil
    end

    # Node kind by directory. Only arc vs root matters (both live in the arcs
    # table); roots carry no lifecycle (status/priority/review).
    def node_kind = self.class.relative_within(@path, Config.roots_dir) ? "root" : "arc"

    # User-driven classification facet from frontmatter `kind:` (system|person|
    # principle|…), orthogonal to node_kind (arc|root). Absent → nil. Mostly used on
    # roots to type reference nodes, but indexed for any node.
    def entity_kind = frontmatter["kind"]&.to_s&.strip

    def title    = (frontmatter["title"] || slug).to_s
    def status   = (frontmatter["status"] || "active").to_s
    def priority = self.class.priority?(frontmatter["priority"])
    def needs_review = %w[true yes 1 on].include?(frontmatter["needs_review"].to_s.strip.downcase)
    # Pinned entities render into pinned.md (always-loaded context). Binary, like priority.
    def pinned   = %w[true yes 1 on].include?(frontmatter["pinned"].to_s.strip.downcase)
    def tags     = Array(frontmatter["tags"]).map(&:to_s)
    def created  = frontmatter["created"].to_s
    def updated  = frontmatter["updated"].to_s
    # One-line human gist, distinct from title. Absent → "" (callers fall back to title).
    def synopsis = frontmatter["synopsis"].to_s
    # Why needs_review is set, written by whatever raises the flag. Absent → "".
    def flag_note = frontmatter["flag_note"].to_s
    def context  = section_text("Context").strip

    def sources
      Array(frontmatter["sources"]).map do |s|
        kind, ref = s.to_s.split(":", 2)
        { kind: (kind || "ref").strip, ref: ref.to_s.strip }
      end
    end

    # Every [[link]] anywhere in the body becomes an edge. kind = leading path segment.
    def links
      @body.scan(LINK_RE).flatten.uniq.map do |target|
        kind = target.include?("/") ? target.split("/").first : "other"
        { target: target, kind: kind }
      end
    end

    def tasks
      out = []
      section_text("Tasks").each_line do |line|
        m = TASK_RE.match(line)
        next unless m
        done = m[1].downcase == "x"
        text = m[2].strip
        due  = text[DUE_RE, 1]
        wait = text[WAIT_RE, 1]
        state =
          if done then "done"
          elsif text.include?("@blocked") then "blocked"
          elsif !wait.nil? then "waiting"
          elsif text.include?("@paused") then "paused"
          else "open"
          end
        clean = text.gsub(DUE_RE, "").gsub(WAIT_RE, "").gsub(/@blocked|@paused/, "").gsub(/\s{2,}/, " ").strip
        out << { text: clean, done: done, state: state, due: due, waiting_on: (wait unless wait.to_s.empty?) }
      end
      out
    end

    def open_tasks = tasks.reject { |t| t[:done] }

    # Most recent "### <date>" block in ## Log, as an array of entry lines.
    def latest_log
      log = section_text("Log")
      blocks = log.split(/^###\s+/).reject { |b| b.strip.empty? }
      return nil if blocks.empty?
      first = blocks.first
      date, *rest = first.lines
      { date: date.to_s.strip, entries: rest.join.strip }
    end

    def section_text(name) = @sections[name] || ""

    private

    def split_frontmatter(raw)
      return [{}, raw] unless raw.start_with?("---")
      parts = raw.split(/^---\s*$\n/, 3)
      # parts => ["", "<yaml>\n", "<body>"]
      return [{}, raw] if parts.length < 3
      data = YAML.safe_load(parts[1].to_s, permitted_classes: [Date, Time], aliases: true) || {}
      data = {} unless data.is_a?(Hash)
      [data, parts[2].to_s]
    rescue Psych::SyntaxError
      [{ "_frontmatter_error" => true }, raw]
    end

    def split_sections(body)
      sections = {}
      current = "_preamble"
      buf = []
      body.each_line do |line|
        if (m = SECTION_RE.match(line))
          sections[current] = buf.join
          current = m[1].strip
          buf = []
        else
          buf << line
        end
      end
      sections[current] = buf.join
      sections
    end
  end
end
