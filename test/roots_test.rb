require_relative "test_helper"

# Roots are non-lifecycle reference nodes sharing the arcs table (kind='root').
# They parse without status/## Tasks, are excluded from list, and surface through
# search / root reads / backlinks.
class RootsParseTest < Minitest::Test
  include VaultTest

  def test_parses_without_status_or_tasks
    arc = Trellis::Arc.new(write_root("finances", synopsis: "money stuff"))
    assert_equal "root", arc.node_kind
    assert_equal "money stuff", arc.synopsis
    assert_equal [], arc.open_tasks
  end

  def test_nested_slug_is_relative_to_roots_dir
    path = write_root("finances/accounts", title: "Accounts")
    assert_equal "finances/accounts", Trellis::Arc.new(path).slug
    assert_equal "finances/accounts", Trellis::Arc.slug_for(path)
  end

  def test_flat_arc_slug_unchanged
    path = write_arc("billing")
    assert_equal "billing", Trellis::Arc.new(path).slug
    assert_equal "arc", Trellis::Arc.new(path).node_kind
  end
end

class RootsIndexTest < Minitest::Test
  include VaultTest

  def index
    @index ||= Trellis::Index.new
  end

  def test_reindex_reconstructs_root_with_null_lifecycle
    write_root("car", synopsis: "maintenance log")
    index.reindex_all
    row = index.arc("car")
    assert_equal "root", row["kind"]
    assert_nil row["status"]
    assert_nil row["priority"]
    assert_nil row["needs_review"]
    assert_equal "maintenance log", row["synopsis"]
  end

  def test_list_excludes_roots
    write_arc("billing", status: "active")
    write_root("finances")
    index.reindex_all
    assert_equal %w[billing], index.list_arcs.map { |r| r["slug"] }
  end

  def test_counts_split_arcs_and_roots
    write_arc("billing")
    write_root("finances")
    write_root("travel/japan")
    c = index.reindex_all
    assert_equal 1, c[:arcs]
    assert_equal 2, c[:roots]
  end

  def test_resolve_slug_scopes_by_kind
    write_arc("billing")
    write_root("finances")
    index.reindex_all
    assert_equal "finances", index.resolve_slug("fin", kind: "root")
    assert_raises(Trellis::Index::NotFound) { index.resolve_slug("finances", kind: "arc") }
    assert_raises(Trellis::Index::NotFound) { index.resolve_slug("billing", kind: "root") }
  end

  def test_search_labels_roots
    write_root("finances", title: "Household finances")
    index.reindex_all
    skip "FTS unavailable" unless index.fts?
    hit = index.search("finances").find { |r| r[:slug] == "finances" }
    assert_equal "root", hit[:type]
  end

  def test_arc_linking_a_root_produces_roots_edge_and_backlink
    write_root("finances/accounts", title: "Accounts")
    path = Trellis::Config.arcs_dir.join("billing.md")
    path.write(<<~MD)
      ---
      title: Billing
      status: active
      updated: 2026-01-01
      ---

      ## Context
      Ties into [[roots/finances/accounts]].

      ## Tasks

      ## Log
    MD
    index.reindex_all
    edge = index.all_edges.find { |e| e["target"] == "roots/finances/accounts" }
    refute_nil edge
    assert_equal "roots", edge["kind"]
    assert_equal %w[billing], index.backlinks("roots/finances/accounts")
  end
end

class RootsStoreTest < Minitest::Test
  include VaultTest

  def test_new_root_flat
    path = Trellis::Store.new_root(title: "Car maintenance", tags: ["home"])
    assert_equal Trellis::Config.roots_dir.join("car-maintenance.md").to_s, path.to_s
    refute_includes path.read, "## Tasks"
    refute_includes path.read, "status:"
  end

  def test_new_root_nested_via_area
    path = Trellis::Store.new_root(title: "Accounts", area: "Finances")
    assert_equal Trellis::Config.roots_dir.join("finances/accounts.md").to_s, path.to_s
    assert_equal "finances/accounts", Trellis::Arc.slug_for(path)
  end

  def test_capture_appends_to_root_log
    write_root("finances")
    Trellis::Store.capture("refinanced, new account at X", root: "finances")
    body = Trellis::Config.roots_dir.join("finances.md").read
    assert_includes body, "refinanced, new account at X"
  end
end
