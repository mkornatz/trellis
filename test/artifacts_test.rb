require_relative "test_helper"

# Artifacts are FTS-only long-form docs. They shard into YYYY/MM/ subfolders by
# first-added date, so indexing globs recursively and slugs stay path-relative
# (unique across months). They surface through search and [[artifacts/...]] links.
class ArtifactsTest < Minitest::Test
  include VaultTest

  def index
    @index ||= Trellis::Index.new
  end

  def test_nested_slug_is_relative_to_artifacts_dir
    path = write_artifact("2026/03/mcp-server-integration-plan")
    assert_equal "2026/03/mcp-server-integration-plan", Trellis::Arc.new(path).slug
    assert_equal "2026/03/mcp-server-integration-plan", Trellis::Arc.slug_for(path)
  end

  def test_nested_artifact_is_indexed_and_searchable
    write_artifact("2026/07/rewards-ledger", title: "Rewards ledger", body: "double entry accounting")
    index.reindex_all
    skip "FTS unavailable" unless index.fts?
    hit = index.search("double entry").find { |r| r[:slug] == "2026/07/rewards-ledger" }
    refute_nil hit
    assert_equal "artifact", hit[:type]
  end

  def test_counts_include_nested_artifacts_across_months
    write_artifact("2026/03/one")
    write_artifact("2026/07/two")
    c = index.reindex_all
    skip "FTS unavailable" unless index.fts?
    assert_equal 2, c[:artifacts]
  end

  def test_arc_links_nested_artifact_via_full_path
    write_artifact("2026/03/plan", title: "Plan")
    path = Trellis::Config.arcs_dir.join("billing.md")
    path.write(<<~MD)
      ---
      title: Billing
      status: active
      updated: 2026-01-01
      ---

      ## Context
      See [[artifacts/2026/03/plan]].

      ## Tasks

      ## Log
    MD
    index.reindex_all
    edge = index.all_edges.find { |e| e["target"] == "artifacts/2026/03/plan" }
    refute_nil edge
    assert_equal "artifacts", edge["kind"]
    assert_equal %w[billing], index.backlinks("artifacts/2026/03/plan")
  end
end
