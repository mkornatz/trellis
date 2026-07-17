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
