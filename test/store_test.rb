require_relative "test_helper"

# set_priority is binary: on writes `priority: true`, off strips the key.
class StoreTest < Minitest::Test
  include VaultTest

  def frontmatter(slug)
    raw = Trellis::Config.arcs_dir.join("#{slug}.md").read
    YAML.safe_load(raw.split(/^---\s*$\n/, 3)[1])
  end

  def test_on_adds_priority_true_when_absent
    write_arc("a") # no priority key
    Trellis::Store.set_priority(slug: "a", on: true)
    assert_equal true, frontmatter("a")["priority"]
  end

  def test_priority_line_sits_after_status
    write_arc("a")
    Trellis::Store.set_priority(slug: "a", on: true)
    lines = Trellis::Config.arcs_dir.join("a.md").read.lines.map(&:chomp)
    status_i   = lines.index { |l| l.start_with?("status:") }
    priority_i = lines.index { |l| l.start_with?("priority:") }
    assert priority_i == status_i + 1, "expected priority directly after status"
  end

  def test_off_strips_the_key
    write_arc("a", priority: true)
    Trellis::Store.set_priority(slug: "a", on: false)
    refute frontmatter("a").key?("priority"), "priority key should be removed"
  end

  def test_on_is_idempotent
    write_arc("a", priority: true)
    Trellis::Store.set_priority(slug: "a", on: true)
    assert_equal true, frontmatter("a")["priority"]
    assert_equal 1, Trellis::Config.arcs_dir.join("a.md").read.scan(/^priority:/).length
  end

  def test_does_not_bump_updated
    write_arc("a", updated: "2026-01-01")
    Trellis::Store.set_priority(slug: "a", on: true)
    assert_equal "2026-01-01", frontmatter("a")["updated"].to_s
  end

  # set_review mirrors set_priority: on writes `needs_review: true`, off strips the key.
  def test_review_on_adds_needs_review_true
    write_arc("a")
    Trellis::Store.set_review(slug: "a", on: true)
    assert_equal true, frontmatter("a")["needs_review"]
  end

  def test_review_off_strips_the_key
    write_arc("a", needs_review: true)
    Trellis::Store.set_review(slug: "a", on: false)
    refute frontmatter("a").key?("needs_review"), "needs_review key should be removed"
  end

  def test_review_does_not_bump_updated
    write_arc("a", updated: "2026-01-01")
    Trellis::Store.set_review(slug: "a", on: true)
    assert_equal "2026-01-01", frontmatter("a")["updated"].to_s
  end

  def test_review_note_sets_flag_note
    write_arc("a")
    Trellis::Store.set_review(slug: "a", on: true, note: "blocker cleared, resume")
    assert_equal true, frontmatter("a")["needs_review"]
    assert_equal "blocker cleared, resume", frontmatter("a")["flag_note"]
  end

  def test_review_off_clears_flag_note
    write_arc("a", needs_review: true, flag_note: "was blocked")
    Trellis::Store.set_review(slug: "a", on: false)
    refute frontmatter("a").key?("needs_review")
    refute frontmatter("a").key?("flag_note"), "resolving review should drop the reason"
  end

  def test_review_on_without_note_keeps_existing_flag_note
    write_arc("a", flag_note: "prior reason")
    Trellis::Store.set_review(slug: "a", on: true)
    assert_equal "prior reason", frontmatter("a")["flag_note"]
  end

  # set_frontmatter is the generic scalar-string write path (synopsis, flag_note).
  def test_set_frontmatter_adds_key_when_absent
    write_arc("a")
    Trellis::Store.set_frontmatter(slug: "a", key: "synopsis", value: "billing revamp")
    assert_equal "billing revamp", frontmatter("a")["synopsis"]
  end

  def test_set_frontmatter_new_key_sits_after_title
    write_arc("a")
    Trellis::Store.set_frontmatter(slug: "a", key: "synopsis", value: "gist")
    lines = Trellis::Config.arcs_dir.join("a.md").read.lines.map(&:chomp)
    title_i = lines.index { |l| l.start_with?("title:") }
    syn_i   = lines.index { |l| l.start_with?("synopsis:") }
    assert syn_i == title_i + 1, "expected synopsis directly after title"
  end

  def test_set_frontmatter_updates_existing_key
    write_arc("a", synopsis: "old")
    Trellis::Store.set_frontmatter(slug: "a", key: "synopsis", value: "new")
    assert_equal "new", frontmatter("a")["synopsis"]
    assert_equal 1, Trellis::Config.arcs_dir.join("a.md").read.scan(/^synopsis:/).length
  end

  def test_set_frontmatter_empty_value_strips_key
    write_arc("a", flag_note: "was blocked")
    Trellis::Store.set_frontmatter(slug: "a", key: "flag_note", value: "")
    refute frontmatter("a").key?("flag_note"), "empty value should strip the key"
  end

  def test_set_frontmatter_roundtrips_special_chars
    write_arc("a")
    val = 'blocked: waiting on "review" from X'
    Trellis::Store.set_frontmatter(slug: "a", key: "flag_note", value: val)
    assert_equal val, frontmatter("a")["flag_note"]
  end

  def test_set_frontmatter_does_not_bump_updated
    write_arc("a", updated: "2026-01-01")
    Trellis::Store.set_frontmatter(slug: "a", key: "synopsis", value: "gist")
    assert_equal "2026-01-01", frontmatter("a")["updated"].to_s
  end
end
