require_relative "test_helper"

# Priority is binary. Arc#priority? decides whether an arc is flagged from its
# frontmatter value, accepting YAML booleans plus legacy pre-binary strings.
class ArcTest < Minitest::Test
  include VaultTest

  def priority_of(value)
    path = write_arc("a", priority: value)
    Trellis::Arc.new(path).priority
  end

  def test_boolean_true_is_flagged
    assert_equal true, priority_of(true)
  end

  def test_boolean_false_is_not_flagged
    assert_equal false, priority_of(false)
  end

  def test_absent_is_not_flagged
    path = write_arc("a") # priority key omitted
    assert_equal false, Trellis::Arc.new(path).priority
  end

  def test_legacy_high_stays_flagged
    assert_equal true, priority_of("H")
  end

  def test_legacy_medium_and_low_stay_flagged
    assert_equal true, priority_of("M")
    assert_equal true, priority_of("L")
  end

  def test_yes_string_is_flagged
    assert_equal true, priority_of("yes")
  end

  def test_empty_string_is_not_flagged
    assert_equal false, priority_of("")
  end

  def test_unknown_string_is_not_flagged
    assert_equal false, priority_of("maybe")
  end

  # needs_review is a separate binary flag, orthogonal to priority and status.
  def review_of(value)
    path = write_arc("r", needs_review: value)
    Trellis::Arc.new(path).needs_review
  end

  def test_needs_review_boolean_true
    assert_equal true, review_of(true)
  end

  def test_needs_review_boolean_false
    assert_equal false, review_of(false)
  end

  def test_needs_review_absent_is_false
    assert_equal false, Trellis::Arc.new(write_arc("r")).needs_review
  end

  # synopsis + flag_note are optional free-string frontmatter; absent parses as "".
  def test_synopsis_and_flag_note_parse
    path = write_arc("s", synopsis: "one-line gist", flag_note: "blocker resolved")
    arc = Trellis::Arc.new(path)
    assert_equal "one-line gist", arc.synopsis
    assert_equal "blocker resolved", arc.flag_note
  end

  def test_synopsis_and_flag_note_absent_are_empty
    arc = Trellis::Arc.new(write_arc("s"))
    assert_equal "", arc.synopsis
    assert_equal "", arc.flag_note
  end
end

# latest_log returns only the newest date block, capped so a single verbose session
# can't bloat every rehydrate; full_log returns everything. (R1)
class LatestLogTest < Minitest::Test
  include VaultTest

  def arc(slug) = Trellis::Arc.new(Trellis::Store.arc_path(slug))

  def test_returns_only_the_newest_block
    write_arc("a")
    Trellis::Store.append_log(slug: "a", text: "old note", date: "2026-01-01")
    Trellis::Store.append_log(slug: "a", text: "new note", date: "2026-02-01")
    log = arc("a").latest_log
    assert_equal "2026-02-01", log[:date]
    assert_includes log[:entries], "new note"
    refute_includes log[:entries], "old note"
  end

  def test_small_block_is_not_truncated
    write_arc("a")
    Trellis::Store.append_log(slug: "a", text: "small", date: "2026-02-01")
    log = arc("a").latest_log
    refute log[:truncated]
    assert_includes log[:entries], "small"
  end

  def test_fat_block_is_capped_and_flagged_keeping_newest
    write_arc("a")
    20.times { |i| Trellis::Store.append_log(slug: "a", text: "entry#{i} #{'x' * 200}", date: "2026-02-01") }
    log = arc("a").latest_log
    assert log[:truncated], "expected truncation"
    assert log[:entries].bytesize <= Trellis::Arc::LOG_BLOCK_BUDGET + 250
    assert_includes log[:entries], "entry19", "newest (prepended) entry survives"
    refute_includes log[:entries], "entry0", "oldest entry in the block is dropped"
  end

  def test_single_entry_over_budget_still_returned
    write_arc("a")
    Trellis::Store.append_log(slug: "a", text: "z" * 5000, date: "2026-02-01")
    log = arc("a").latest_log(max_bytes: 100)
    assert_includes log[:entries], "z", "never drops the only entry"
  end

  def test_max_bytes_nil_returns_whole_block
    write_arc("a")
    20.times { |i| Trellis::Store.append_log(slug: "a", text: "entry#{i} #{'x' * 200}", date: "2026-02-01") }
    log = arc("a").latest_log(max_bytes: nil)
    refute log[:truncated]
    assert_includes log[:entries], "entry0"
  end

  def test_full_log_returns_all_blocks
    write_arc("a")
    Trellis::Store.append_log(slug: "a", text: "old", date: "2026-01-01")
    Trellis::Store.append_log(slug: "a", text: "new", date: "2026-02-01")
    full = arc("a").full_log
    assert_includes full, "old"
    assert_includes full, "new"
  end
end
