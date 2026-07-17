require_relative "test_helper"

# pinned is a binary flag (like priority) that applies to arcs AND roots.
class PinnedFlagTest < Minitest::Test
  include VaultTest

  def frontmatter(path)
    YAML.safe_load(path.read.split(/^---\s*$\n/, 3)[1])
  end

  def test_arc_pinned_parses
    path = write_arc("a")
    Trellis::Store.set_pinned(slug: "a", on: true)
    assert_equal true, Trellis::Arc.new(path).pinned
  end

  def test_absent_pinned_is_false
    assert_equal false, Trellis::Arc.new(write_arc("a")).pinned
  end

  def test_set_pinned_on_arc_sits_after_title_and_strips
    write_arc("a")
    Trellis::Store.set_pinned(slug: "a", on: true)
    lines = Trellis::Config.arcs_dir.join("a.md").read.lines.map(&:chomp)
    assert_equal lines.index { |l| l.start_with?("title:") } + 1,
                 lines.index { |l| l.start_with?("pinned:") }
    Trellis::Store.set_pinned(slug: "a", on: false)
    refute frontmatter(Trellis::Config.arcs_dir.join("a.md")).key?("pinned")
  end

  def test_set_pinned_works_on_a_root_without_status_line
    write_root("finances")
    Trellis::Store.set_pinned(slug: "finances", on: true, kind: "root")
    assert_equal true, frontmatter(Trellis::Config.roots_dir.join("finances.md"))["pinned"]
  end

  def test_set_pinned_does_not_bump_updated
    write_arc("a", updated: "2026-01-01")
    Trellis::Store.set_pinned(slug: "a", on: true)
    assert_equal "2026-01-01", frontmatter(Trellis::Config.arcs_dir.join("a.md"))["updated"].to_s
  end
end

class PinnedIndexTest < Minitest::Test
  include VaultTest

  def index = @index ||= Trellis::Index.new

  def test_reindex_reconstructs_pinned
    write_arc("a")
    Trellis::Store.set_pinned(slug: "a", on: true)
    index.reindex_all
    assert_equal "true", index.arc("a")["pinned"]
  end

  def test_pinned_entities_arcs_then_roots
    write_arc("billing", status: "active")
    write_root("finances")
    Trellis::Store.set_pinned(slug: "billing", on: true)
    Trellis::Store.set_pinned(slug: "finances", on: true, kind: "root")
    write_arc("unpinned")
    index.reindex_all
    assert_equal %w[billing finances], index.pinned_entities.map { |r| r["slug"] }
  end
end

# pinned.md is a derived file — delete it, regenerate, get the same bytes.
class PinnedRenderTest < Minitest::Test
  include VaultTest

  def index = @index ||= Trellis::Index.new

  def setup_pinned
    write_arc("billing", status: "active", title: "Billing revamp", synopsis: "Q3 rebuild")
    Trellis::Store.set_pinned(slug: "billing", on: true)
    index.reindex_all
  end

  def test_regenerate_writes_pinned_file
    setup_pinned
    Trellis::Store.regenerate_pinned(index.pinned_entities)
    body = Trellis::Config.pinned_path.read
    assert_includes body, "# Pinned — trellis"
    assert_includes body, "## Billing revamp  [active]"
    assert_includes body, "Q3 rebuild"
  end

  def test_pinned_file_is_derivable
    setup_pinned
    Trellis::Store.regenerate_pinned(index.pinned_entities)
    first = Trellis::Config.pinned_path.read
    Trellis::Config.pinned_path.delete
    Trellis::Store.regenerate_pinned(index.pinned_entities)
    assert_equal first, Trellis::Config.pinned_path.read
  end

  def test_no_pinned_entities_writes_placeholder
    setup_pinned
    Trellis::Store.regenerate_pinned(index.pinned_entities)
    assert_includes Trellis::Config.pinned_path.read, "Billing revamp"
    Trellis::Store.set_pinned(slug: "billing", on: false)
    index.reindex_all
    Trellis::Store.regenerate_pinned(index.pinned_entities)
    # File stays (placeholder), so a wired @import never dangles.
    assert Trellis::Config.pinned_path.exist?
    assert_includes Trellis::Config.pinned_path.read, "Nothing pinned"
    refute_includes Trellis::Config.pinned_path.read, "Billing revamp"
  end

  def test_budget_truncates_with_marker
    (1..10).each { |i| write_arc(format("arc-%02d", i), synopsis: "synopsis #{i}") }
    (1..10).each { |i| Trellis::Store.set_pinned(slug: format("arc-%02d", i), on: true) }
    index.reindex_all
    ENV["TRELLIS_PINNED_BUDGET"] = "12"
    res = Trellis::Store.regenerate_pinned(index.pinned_entities)
    ensure_reset = -> { ENV.delete("TRELLIS_PINNED_BUDGET") }
    assert res[:truncated].positive?, "expected truncation under a tight budget"
    assert_includes Trellis::Config.pinned_path.read, "more pinned"
    ensure_reset.call
  end
end

# Wiring the import into ~/.claude/CLAUDE.md (isolated to tmp via TRELLIS_CLAUDE_MD).
class PinnedImportTest < Minitest::Test
  include VaultTest

  def claude_md = Trellis::Config.claude_md

  def test_create_false_noops_when_file_absent
    refute claude_md.exist?
    assert_equal({ wired: false }, Trellis::Store.ensure_pinned_import(create: false))
    refute claude_md.exist?, "must not conjure a global config file"
  end

  def test_create_true_creates_and_wires
    res = Trellis::Store.ensure_pinned_import(create: true)
    assert res[:wired]
    assert_includes claude_md.read, Trellis::Config.pinned_import_line
  end

  def test_is_idempotent_and_additive
    claude_md.write("# My config\n\nexisting content\n")
    Trellis::Store.ensure_pinned_import(create: false)
    Trellis::Store.ensure_pinned_import(create: false)
    body = claude_md.read
    assert_includes body, "existing content"
    assert_equal 1, body.scan(Trellis::Config.pinned_import_line).length
  end

  def test_regenerate_wires_when_claude_md_exists
    claude_md.write("# config\n")
    write_arc("a")
    Trellis::Store.set_pinned(slug: "a", on: true)
    idx = Trellis::Index.new
    idx.reindex_all
    Trellis::Store.regenerate_pinned(idx.pinned_entities)
    assert_includes claude_md.read, Trellis::Config.pinned_import_line
  end
end
