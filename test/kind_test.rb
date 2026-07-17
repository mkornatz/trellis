require_relative "test_helper"

# The `kind:` frontmatter facet (entity_kind) — a user-driven classification
# (system|person|principle|…) orthogonal to node_kind (arc|root). Mostly on roots.
class KindParseTest < Minitest::Test
  include VaultTest

  def test_parses_entity_kind_from_frontmatter
    arc = Trellis::Arc.new(write_root("snowflake", kind: "system"))
    assert_equal "system", arc.entity_kind
    assert_equal "root", arc.node_kind
  end

  def test_entity_kind_absent_is_nil
    assert_nil Trellis::Arc.new(write_root("finances")).entity_kind
  end
end

class KindIndexTest < Minitest::Test
  include VaultTest

  def index = @index ||= Trellis::Index.new

  def test_reindex_stores_entity_kind
    write_root("snowflake", kind: "system")
    index.reindex_all
    assert_equal "system", index.arc("snowflake")["entity_kind"]
  end

  def test_roots_filters_by_kind
    write_root("snowflake", kind: "system")
    write_root("payments-api", kind: "system")
    write_root("jordan-lee", kind: "person")
    write_root("finances") # untyped
    index.reindex_all

    assert_equal %w[payments-api snowflake], index.roots(kind: "system").map { |r| r["slug"] }
    assert_equal %w[jordan-lee], index.roots(kind: "person").map { |r| r["slug"] }
    assert_equal 4, index.roots.length
  end

  def test_entity_kinds_vocabulary_with_counts
    write_root("snowflake", kind: "system")
    write_root("payments-api", kind: "system")
    write_root("jordan-lee", kind: "person")
    index.reindex_all
    vocab = index.entity_kinds.to_h { |r| [r["kind"], r["n"]] }
    assert_equal({ "person" => 1, "system" => 2 }, vocab)
  end

  def test_search_includes_kind
    write_root("snowflake", title: "Snowflake warehouse", kind: "system")
    index.reindex_all
    skip "FTS unavailable" unless index.fts?
    hit = index.search("Snowflake").find { |r| r[:slug] == "snowflake" }
    assert_equal "root", hit[:type]
    assert_equal "system", hit[:kind]
  end
end

class KindStoreTest < Minitest::Test
  include VaultTest

  def test_new_root_with_kind_writes_frontmatter
    path = Trellis::Store.new_root(title: "Snowflake", kind: "system")
    body = path.read
    assert_includes body, "kind: system"
    assert_equal "system", Trellis::Arc.new(path).entity_kind
  end

  def test_new_root_without_kind_omits_key
    path = Trellis::Store.new_root(title: "Finances")
    refute_includes path.read, "kind:"
  end
end
