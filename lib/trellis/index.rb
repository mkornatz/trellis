require "sqlite3"
require "json"

module Trellis
  # SQLite index — derived from the Markdown, never authoritative. `reindex` rebuilds it.
  class Index
    class Ambiguous < StandardError; end
    class NotFound < StandardError; end

    # Bump when the FTS schema or tokenizer changes. FTS5 has no ALTER, and a plain
    # reindex only DELETEs rows (the tokenizer survives) — so a change here forces a
    # one-time DROP + rebuild, gated on PRAGMA user_version so it fires exactly once.
    FTS_SCHEMA_VERSION = 2

    def initialize(db_path = Config.db_path)
      raise "vault not found at #{Config.vault} (check TRELLIS_VAULT, or mount it)" unless Config.vault.exist?

      path = Pathname.new(db_path)
      path.dirname.mkpath
      @db = SQLite3::Database.new(path.to_s)
      @db.results_as_hash = true
      @fts = true
      migrate
    end

    def migrate
      @db.execute_batch <<~SQL
        CREATE TABLE IF NOT EXISTS arcs(
          slug TEXT PRIMARY KEY, title TEXT, status TEXT, tags TEXT,
          created TEXT, updated TEXT, path TEXT, mtime REAL, context TEXT,
          priority TEXT, needs_review TEXT, synopsis TEXT, flag_note TEXT,
          kind TEXT, pinned TEXT, entity_kind TEXT
        );
        CREATE TABLE IF NOT EXISTS tasks(
          arc TEXT, idx INTEGER, text TEXT, state TEXT, waiting_on TEXT, due TEXT, done INTEGER
        );
        CREATE TABLE IF NOT EXISTS edges(src TEXT, target TEXT, kind TEXT);
        CREATE TABLE IF NOT EXISTS sources(arc TEXT, kind TEXT, ref TEXT);
        CREATE INDEX IF NOT EXISTS idx_tasks_arc   ON tasks(arc);
        CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
        CREATE INDEX IF NOT EXISTS idx_edges_src    ON edges(src);
        CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target);
        CREATE INDEX IF NOT EXISTS idx_sources_arc  ON sources(arc);
      SQL
      # Add priority to pre-existing indexes (CREATE TABLE IF NOT EXISTS won't backfill columns).
      begin
        @db.execute("ALTER TABLE arcs ADD COLUMN priority TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      begin
        @db.execute("ALTER TABLE arcs ADD COLUMN needs_review TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      begin
        @db.execute("ALTER TABLE arcs ADD COLUMN synopsis TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      begin
        @db.execute("ALTER TABLE arcs ADD COLUMN flag_note TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      begin
        # kind: 'arc' | 'root'. NULL on pre-migration rows reads as 'arc'.
        @db.execute("ALTER TABLE arcs ADD COLUMN kind TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      begin
        @db.execute("ALTER TABLE arcs ADD COLUMN pinned TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      begin
        # entity_kind: user-driven facet from frontmatter `kind:` (system|person|…). NULL when absent.
        @db.execute("ALTER TABLE arcs ADD COLUMN entity_kind TEXT")
      rescue SQLite3::SQLException
        # column already exists
      end
      rebuilt = false
      begin
        # Tokenizer/schema change: drop the FTS tables once so they recreate with the
        # current definition. reindex_all below repopulates them from the vault.
        if @db.get_first_value("PRAGMA user_version").to_i < FTS_SCHEMA_VERSION
          %w[arcs_fts artifacts_fts].each { |t| @db.execute("DROP TABLE IF EXISTS #{t}") }
          @db.execute("PRAGMA user_version = #{FTS_SCHEMA_VERSION}")
          rebuilt = true
        end
        rebuilt |= ensure_fts_table("arcs_fts")
        rebuilt |= ensure_fts_table("artifacts_fts")
      rescue SQLite3::SQLException
        @fts = false
      end
      # A stale FTS table (dropped above) is empty until repopulated from the vault.
      reindex_all if rebuilt
    end

    # FTS5 has no ALTER ADD COLUMN; drop a schema-stale table so it can be recreated
    # with the current columns. Returns true if an existing table was dropped.
    def ensure_fts_table(name)
      cols = @db.execute("PRAGMA table_info(#{name})").map { |r| r["name"] }
      dropped = cols.any? && !cols.include?("tags")
      @db.execute("DROP TABLE #{name}") if dropped
      # porter stemming so plural/tense variants match (rebate ↔ rebates, source ↔ sourcing).
      @db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS #{name} USING fts5(slug, title, body, tags, tokenize='porter unicode61')")
      dropped
    end

    def fts? = @fts

    # ---- write (derived) --------------------------------------------------

    def reindex_all
      %w[arcs tasks edges sources].each { |t| @db.execute("DELETE FROM #{t}") }
      if @fts
        @db.execute("DELETE FROM arcs_fts")
        @db.execute("DELETE FROM artifacts_fts")
      end
      Config.arcs_dir.glob("*.md").sort.each { |f| index_arc(Arc.new(f)) }
      # Roots share the arcs table (kind='root') and may be nested in subfolders.
      if Config.roots_dir.exist?
        Config.roots_dir.glob("**/*.md").sort.each { |f| index_arc(Arc.new(f)) }
      end
      # Artifacts may be sharded into YYYY/MM/ subfolders, so glob recursively
      # (like roots). Nested slugs stay unique via Arc.slug_for (path-relative).
      if Config.artifacts_dir.exist?
        Config.artifacts_dir.glob("**/*.md").sort.each { |f| index_artifact(Arc.new(f)) }
      end
      counts
    end

    def index_arc(arc)
      remove(arc.slug)
      kind = arc.node_kind
      root = kind == "root"
      # Roots have no lifecycle — status/priority/needs_review/flag_note stay NULL.
      # pinned applies to both kinds (arcs and roots can be pinned).
      @db.execute(
        "INSERT INTO arcs(slug,title,status,tags,created,updated,path,mtime,context,priority,needs_review,synopsis,flag_note,kind,pinned,entity_kind) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [arc.slug, arc.title, (root ? nil : arc.status), JSON.dump(arc.tags), arc.created, arc.updated,
         arc.path.to_s, arc.path.mtime.to_f, arc.context, (root ? nil : (arc.priority ? "true" : nil)),
         (root ? nil : (arc.needs_review ? "true" : nil)),
         (arc.synopsis.empty? ? nil : arc.synopsis), (root ? nil : (arc.flag_note.empty? ? nil : arc.flag_note)),
         kind, (arc.pinned ? "true" : nil), (arc.entity_kind.to_s.empty? ? nil : arc.entity_kind)]
      )
      arc.tasks.each_with_index do |t, i|
        @db.execute("INSERT INTO tasks(arc,idx,text,state,waiting_on,due,done) VALUES (?,?,?,?,?,?,?)",
                    [arc.slug, i + 1, t[:text], t[:state], t[:waiting_on], t[:due], t[:done] ? 1 : 0])
      end
      arc.links.each { |l| @db.execute("INSERT INTO edges(src,target,kind) VALUES (?,?,?)", [arc.slug, l[:target], l[:kind]]) }
      arc.sources.each { |s| @db.execute("INSERT INTO sources(arc,kind,ref) VALUES (?,?,?)", [arc.slug, s[:kind], s[:ref]]) }
      @db.execute("INSERT INTO arcs_fts(slug,title,body,tags) VALUES (?,?,?,?)", [arc.slug, arc.title, arc.body, arc.tags.join(" ")]) if @fts
    end

    # Artifacts (long-form docs) are FTS-only — link targets with searchable content.
    def index_artifact(artifact)
      return unless @fts
      @db.execute("DELETE FROM artifacts_fts WHERE slug = ?", [artifact.slug])
      @db.execute("INSERT INTO artifacts_fts(slug,title,body,tags) VALUES (?,?,?,?)", [artifact.slug, artifact.title, artifact.body, artifact.tags.join(" ")])
    end

    def remove(slug)
      @db.execute("DELETE FROM arcs   WHERE slug = ?", [slug])
      @db.execute("DELETE FROM tasks  WHERE arc  = ?", [slug])
      @db.execute("DELETE FROM edges  WHERE src  = ?", [slug])
      @db.execute("DELETE FROM sources WHERE arc = ?", [slug])
      @db.execute("DELETE FROM arcs_fts WHERE slug = ?", [slug]) if @fts
    end

    # ---- read -------------------------------------------------------------

    # List ordering, tiered:
    #   1. needs_review   — arcs awaiting a human decision float above all else
    #   2. priority flag  — flagged arcs (the focus set) float to the top
    #   3. status weight  — active > waiting > paused > done > dropped
    #   4. recency        — most-recently-updated first
    #   5. slug           — stable tiebreak
    # Review is the top tier so a done/paused arc with a fresh signal surfaces despite
    # its status. No manual ranking: recency within a status bucket is the "what's warm" proxy.
    REVIEW_RANK   = "CASE WHEN needs_review = 'true' THEN 0 ELSE 1 END"
    PRIORITY_RANK = "CASE WHEN priority = 'true' THEN 0 ELSE 1 END"
    STATUS_RANK   = "CASE status WHEN 'active' THEN 0 WHEN 'waiting' THEN 1 WHEN 'paused' THEN 2 " \
                    "WHEN 'done' THEN 3 WHEN 'dropped' THEN 4 ELSE 5 END"
    LIST_ORDER    = "#{REVIEW_RANK}, #{PRIORITY_RANK}, #{STATUS_RANK}, updated DESC, slug".freeze
    # Roots share the table but carry no lifecycle, so list/tasks/review exclude them.
    # NULL kind = a pre-migration row, which is always an arc.
    ARC_ONLY      = "(kind = 'arc' OR kind IS NULL)".freeze

    def list_arcs(status: nil)
      if status
        @db.execute("SELECT * FROM arcs WHERE #{ARC_ONLY} AND status = ? ORDER BY #{LIST_ORDER}", [status])
      else
        @db.execute("SELECT * FROM arcs WHERE #{ARC_ONLY} ORDER BY #{LIST_ORDER}")
      end
    end

    # A quick glance, not a full list: the same `list` ordering, capped. Both
    # interfaces share this so "what shows and in what order" lives in one place;
    # they differ only in formatting. Returns [rows (≤ limit), total arc count].
    OVERVIEW_LIMIT = 20
    def overview(limit: OVERVIEW_LIMIT)
      all = list_arcs
      [all.first(limit), all.length]
    end

    # Pinned entities (arcs + roots) for pinned.md, arcs first (list order) then roots.
    def pinned_entities
      @db.execute("SELECT * FROM arcs WHERE pinned = 'true' ORDER BY (kind = 'root'), #{LIST_ORDER}")
    end

    # Resolve a full slug or unique prefix. Raises on none / ambiguous.
    # kind: "arc" | "root" scopes resolution so `arc x` never matches a root and
    # vice versa; nil resolves across both.
    def resolve_slug(query, kind: nil)
      f = kind_filter(kind)
      exact = @db.get_first_value("SELECT slug FROM arcs WHERE slug = ?#{f}", [query])
      return exact if exact
      hits = @db.execute("SELECT slug FROM arcs WHERE slug LIKE ?#{f} ORDER BY slug", ["#{query}%"]).map { |r| r["slug"] }
      raise NotFound, query if hits.empty?
      raise Ambiguous, "#{query} → #{hits.join(', ')}" if hits.length > 1
      hits.first
    end

    def kind_filter(kind)
      case kind
      when "root" then " AND kind = 'root'"
      when "arc"  then " AND #{ARC_ONLY}"
      else ""
      end
    end

    # The decision inbox: every arc flagged for review, top-tier ordering.
    def review_arcs = @db.execute("SELECT * FROM arcs WHERE needs_review = 'true' ORDER BY #{LIST_ORDER}")

    def arc(slug)      = @db.execute("SELECT * FROM arcs WHERE slug = ?", [slug]).first
    def tasks_for(slug) = @db.execute("SELECT * FROM tasks WHERE arc = ? ORDER BY idx", [slug])
    def sources_for(slug) = @db.execute("SELECT * FROM sources WHERE arc = ?", [slug])

    # Open tasks across arcs. Defaults to active arcs only — paused/waiting/etc. arcs
    # are "not on my plate now" and drop out unless all: true (or a specific arc is named).
    def open_tasks(state: nil, arc: nil, all: false)
      sql = "SELECT t.*, a.title AS arc_title, a.status AS arc_status FROM tasks t JOIN arcs a ON a.slug = t.arc WHERE t.done = 0"
      args = []
      if arc
        sql += " AND t.arc = ?"; args << arc
      elsif !all
        sql += " AND a.status = 'active'"
      end
      if state then sql += " AND t.state = ?"; args << state end
      sql += " ORDER BY (t.due IS NULL), t.due, t.arc"
      @db.execute(sql, args)
    end

    # Count of open tasks hidden from the default view (in non-active arcs).
    def hidden_task_count
      @db.get_first_value("SELECT COUNT(*) FROM tasks t JOIN arcs a ON a.slug = t.arc WHERE t.done = 0 AND a.status != 'active'")
    end

    # Arcs connected to slug: ones it links to (that are arcs), ones linking to it,
    # and ones sharing a non-arc target (same system/person).
    def related(slug)
      linked_out = @db.execute("SELECT target FROM edges WHERE src = ? AND kind = 'arcs'", [slug]).map { |r| r["target"].split("/").last }
      linked_in  = @db.execute("SELECT src FROM edges WHERE target LIKE ? ", ["%#{slug}"]).map { |r| r["src"] }
      shared = @db.execute(<<~SQL, [slug, slug])
        SELECT DISTINCT e2.src FROM edges e1
        JOIN edges e2 ON e1.target = e2.target AND e1.kind != 'arcs'
        WHERE e1.src = ? AND e2.src != ?
      SQL
      shared = shared.map { |r| r["src"] }
      (linked_out + linked_in + shared).uniq.reject { |s| s == slug }
    end

    def backlinks(target)
      @db.execute("SELECT DISTINCT src FROM edges WHERE target = ? ORDER BY src", [target]).map { |r| r["src"] }
    end

    # Returns [{type:, slug:, title:, snip:}] across arcs + artifacts.
    # Ranking: bm25 relevance (bucketed) then recency, so near-equal matches surface the
    # freshest first. Completed arcs (done/dropped) are excluded; roots (NULL status) stay.
    def search(query, limit: 20)
      return fallback_search(query, limit) unless @fts
      out = []
      @db.execute(<<~SQL, [query, limit]).each do |r|
        SELECT f.slug, f.title,
               snippet(arcs_fts, 2, '', '', '…', 10) AS snip,
               COALESCE(a.kind,'arc') AS kind, a.entity_kind
        FROM arcs_fts f JOIN arcs a ON a.slug = f.slug
        WHERE arcs_fts MATCH ?
          AND (a.status IS NULL OR a.status NOT IN ('done','dropped'))
        ORDER BY ROUND(bm25(arcs_fts), 1), a.updated DESC
        LIMIT ?
      SQL
        out << { type: (r["kind"] == "root" ? "root" : "arc"), kind: r["entity_kind"], slug: r["slug"], title: r["title"], snip: r["snip"] }
      end
      @db.execute(<<~SQL, [query, limit]).each do |r|
        SELECT slug, title, snippet(artifacts_fts, 2, '', '', '…', 10) AS snip
        FROM artifacts_fts WHERE artifacts_fts MATCH ?
        ORDER BY bm25(artifacts_fts) LIMIT ?
      SQL
        out << { type: "artifact", slug: r["slug"], title: r["title"], snip: r["snip"] }
      end
      out
    rescue SQLite3::SQLException
      fallback_search(query, limit)
    end

    def fallback_search(query, limit)
      like = "%#{query}%"
      @db.execute(<<~SQL, [like, like, limit])
        SELECT slug, title, COALESCE(kind,'arc') AS kind, entity_kind FROM arcs
        WHERE (title LIKE ? OR context LIKE ?)
          AND (status IS NULL OR status NOT IN ('done','dropped'))
        LIMIT ?
      SQL
        .map { |r| { type: (r["kind"] == "root" ? "root" : "arc"), kind: r["entity_kind"], slug: r["slug"], title: r["title"], snip: nil } }
    end

    def counts
      {
        arcs:  @db.get_first_value("SELECT COUNT(*) FROM arcs WHERE #{ARC_ONLY}"),
        roots: @db.get_first_value("SELECT COUNT(*) FROM arcs WHERE kind = 'root'"),
        open_tasks: @db.get_first_value("SELECT COUNT(*) FROM tasks WHERE done = 0"),
        edges: @db.get_first_value("SELECT COUNT(*) FROM edges"),
        artifacts: (@fts ? @db.get_first_value("SELECT COUNT(*) FROM artifacts_fts") : 0),
      }
    end

    def root_slugs = @db.execute("SELECT slug FROM arcs WHERE kind = 'root'").map { |r| r["slug"] }

    # Roots, optionally filtered by their frontmatter `kind:` facet (system|person|…).
    # Ordered kind-then-slug; untyped roots (NULL entity_kind) sort last.
    def roots(kind: nil)
      if kind
        @db.execute("SELECT * FROM arcs WHERE kind = 'root' AND entity_kind = ? ORDER BY slug", [kind])
      else
        @db.execute("SELECT * FROM arcs WHERE kind = 'root' ORDER BY (entity_kind IS NULL), entity_kind, slug")
      end
    end

    # Distinct kind facets in use, with counts — the vocabulary as it actually exists.
    def entity_kinds
      @db.execute("SELECT entity_kind AS kind, COUNT(*) AS n FROM arcs WHERE entity_kind IS NOT NULL GROUP BY entity_kind ORDER BY entity_kind")
    end

    def all_edges = @db.execute("SELECT src, target, kind FROM edges")
    def all_arc_paths = @db.execute("SELECT slug, path FROM arcs").to_h { |r| [r["slug"], r["path"]] }
  end
end
