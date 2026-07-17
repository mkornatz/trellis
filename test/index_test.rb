require_relative "test_helper"

# The core behavior change: list ordering is tiered
#   1. priority flag  2. status weight  3. recency  4. slug
class IndexListOrderTest < Minitest::Test
  include VaultTest

  def index
    @index ||= Trellis::Index.new
  end

  def slugs(status: nil)
    index.list_arcs(status: status).map { |r| r["slug"] }
  end

  def test_priority_beats_everything_including_status
    # A flagged but merely-waiting arc still outranks an unflagged active arc.
    write_arc("z-waiting-flagged", status: "waiting", priority: true,  updated: "2026-01-01")
    write_arc("a-active-plain",    status: "active",  updated: "2026-06-01")
    index.reindex_all
    assert_equal %w[z-waiting-flagged a-active-plain], slugs
  end

  def test_full_tiered_ordering
    write_arc("a-active-flag",  status: "active",  priority: true, updated: "2026-01-01")
    write_arc("d-wait-flag",    status: "waiting", priority: true, updated: "2026-06-01")
    write_arc("b-active-new",   status: "active",  updated: "2026-06-01")
    write_arc("c-active-old",   status: "active",  updated: "2026-01-01")
    write_arc("e-paused",       status: "paused",  updated: "2026-06-01")
    write_arc("f-done",         status: "done",    updated: "2026-06-01")
    index.reindex_all

    # flagged (active then waiting), then unflagged by status then recency
    assert_equal %w[a-active-flag d-wait-flag b-active-new c-active-old e-paused f-done], slugs
  end

  def test_recency_breaks_ties_within_a_status_bucket
    write_arc("older", status: "active", updated: "2026-01-01")
    write_arc("newer", status: "active", updated: "2026-06-01")
    index.reindex_all
    assert_equal %w[newer older], slugs
  end

  def test_slug_is_the_final_tiebreak
    write_arc("bbb", status: "active", updated: "2026-01-01")
    write_arc("aaa", status: "active", updated: "2026-01-01")
    index.reindex_all
    assert_equal %w[aaa bbb], slugs
  end

  def test_status_filter_still_priority_first
    write_arc("plain",   status: "active", updated: "2026-06-01")
    write_arc("flagged", status: "active", priority: true, updated: "2026-01-01")
    write_arc("waiting", status: "waiting", updated: "2026-06-01")
    index.reindex_all
    assert_equal %w[flagged plain], slugs(status: "active")
  end

  def test_legacy_high_arc_sorts_as_flagged
    write_arc("legacy", status: "active", priority: "H", updated: "2026-01-01")
    write_arc("plain",  status: "active", updated: "2026-06-01")
    index.reindex_all
    assert_equal %w[legacy plain], slugs
  end

  # needs_review is the top tier: a done arc with a fresh signal outranks even an
  # active, priority-flagged arc — that's the whole point of "reopen?"
  def test_review_beats_priority_and_status
    write_arc("done-signal",  status: "done",   needs_review: true, updated: "2026-01-01")
    write_arc("active-flag",  status: "active", priority: true,     updated: "2026-06-01")
    index.reindex_all
    assert_equal %w[done-signal active-flag], slugs
  end

  def test_review_arcs_returns_only_flagged
    write_arc("flagged", status: "active", needs_review: true)
    write_arc("plain",   status: "active")
    index.reindex_all
    assert_equal %w[flagged], index.review_arcs.map { |r| r["slug"] }
  end
end

# Tags live in frontmatter, not the arc body, so they only surface in search if
# indexed into their own FTS column.
class IndexSearchTest < Minitest::Test
  include VaultTest

  def index
    @index ||= Trellis::Index.new
  end

  def test_search_matches_a_tag
    write_arc("billing-work", tags: ["snowflake"])
    write_arc("other-work",   tags: ["postgres"])
    index.reindex_all
    skip "FTS unavailable" unless index.fts?
    assert_equal %w[billing-work], index.search("snowflake").map { |r| r[:slug] }
  end
end

# synopsis + flag_note are indexed columns populated from frontmatter at reindex time.
# The index starts empty each test, so a populated column proves reconstruction from
# the vault alone (invariant 1: the index is fully derivable from the Markdown).
class IndexSynopsisFlagNoteTest < Minitest::Test
  include VaultTest

  def index
    @index ||= Trellis::Index.new
  end

  def test_reindex_reconstructs_synopsis_and_flag_note
    write_arc("a", synopsis: "one-line gist", flag_note: "why flagged", needs_review: true)
    index.reindex_all
    row = index.arc("a")
    assert_equal "one-line gist", row["synopsis"]
    assert_equal "why flagged", row["flag_note"]
  end

  def test_absent_fields_index_as_null
    write_arc("a")
    index.reindex_all
    row = index.arc("a")
    assert_nil row["synopsis"]
    assert_nil row["flag_note"]
  end
end

# overview reuses list ordering, just capped — a glance, not the full list.
class IndexOverviewTest < Minitest::Test
  include VaultTest

  def index
    @index ||= Trellis::Index.new
  end

  def test_overview_order_matches_list
    write_arc("a-active-flag", status: "active", priority: true, updated: "2026-01-01")
    write_arc("b-active-new",  status: "active", updated: "2026-06-01")
    write_arc("c-done-signal", status: "done",   needs_review: true, updated: "2026-01-01")
    index.reindex_all
    rows, total = index.overview
    assert_equal index.list_arcs.map { |r| r["slug"] }, rows.map { |r| r["slug"] }
    assert_equal 3, total
  end

  def test_overview_caps_and_reports_total
    (1..25).each { |i| write_arc(format("arc-%02d", i)) }
    index.reindex_all
    rows, total = index.overview(limit: 20)
    assert_equal 20, rows.length
    assert_equal 25, total
  end
end
