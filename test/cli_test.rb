require_relative "test_helper"
require "trellis/cli"

# The CLI half of the "roots have no log" rule: reads refuse a root, and doctor
# reports any root still carrying a ## Log so it can be folded into Context.
class CLIRootLogTest < Minitest::Test
  include VaultTest

  def setup
    super
    Trellis::Config.roots_dir.mkpath
  end

  def write_root_with_log(slug)
    path = Trellis::Config.roots_dir.join("#{slug}.md")
    path.write(<<~MD)
      ---
      title: #{slug}
      updated: 2026-01-01
      ---

      ## Context

      ## Log

      ### 2026-01-01
      - stale entry
    MD
    path
  end

  def reindexed_cli
    Trellis::Index.new.reindex_all
    Trellis::CLI.new
  end

  def test_log_refuses_a_root
    write_root("finances")
    cli = reindexed_cli
    out, err = capture_io { assert_raises(SystemExit) { cli.log("finances") } }
    assert_match(/roots have no log/, err)
    refute_match(/no log for/, out)
  end

  def test_log_still_prints_an_arc_log
    write_arc("billing")
    Trellis::Store.append_log(slug: "billing", text: "vendor confirmed")
    out, = capture_io { reindexed_cli.log("billing") }
    assert_match(/vendor confirmed/, out)
  end

  def test_doctor_flags_a_root_carrying_a_log
    write_root_with_log("legacy")
    out, = capture_io { reindexed_cli.doctor }
    assert_match(%r{root-has-log: roots/legacy}, out)
  end

  def test_doctor_clean_when_roots_have_no_log
    write_root("finances")
    write_arc("billing")
    out, = capture_io { reindexed_cli.doctor }
    assert_match(/no drift/, out)
  end
end
