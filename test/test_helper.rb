$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "trellis"

# Every test runs against a throwaway vault under TRELLIS_VAULT, so the real
# ~/trellis is never touched and each test gets a fresh index.
module VaultTest
  def setup
    @vault = Dir.mktmpdir("trellis-test")
    ENV["TRELLIS_VAULT"] = @vault
    # Isolate the pinned.md → CLAUDE.md wiring inside the tmp vault so tests never
    # touch the real ~/.claude/CLAUDE.md.
    ENV["TRELLIS_CLAUDE_MD"] = File.join(@vault, "CLAUDE.md")
    Trellis::Config.arcs_dir.mkpath
  end

  def teardown
    ENV.delete("TRELLIS_VAULT")
    ENV.delete("TRELLIS_CLAUDE_MD")
    FileUtils.remove_entry(@vault) if @vault && File.exist?(@vault)
  end

  # Write a minimal arc file. Omit priority to leave the frontmatter key out entirely.
  # body: fills the ## Context section (feeds the FTS body column for search tests).
  def write_arc(slug, status: "active", updated: "2026-01-01", title: nil, priority: :unset, needs_review: :unset, tags: [], synopsis: :unset, flag_note: :unset, body: "")
    fm = { "title" => (title || slug), "status" => status, "tags" => tags, "updated" => updated }
    fm["priority"] = priority unless priority == :unset
    fm["needs_review"] = needs_review unless needs_review == :unset
    fm["synopsis"] = synopsis unless synopsis == :unset
    fm["flag_note"] = flag_note unless flag_note == :unset
    path = Trellis::Config.arcs_dir.join("#{slug}.md")
    path.write(<<~MD)
      ---
      #{YAML.dump(fm).delete_prefix("---\n").strip}
      ---

      ## Context

      #{body}

      ## Tasks

      ## Log
    MD
    path
  end

  # Write a root file (no status, no ## Tasks). slug may contain "/" for nesting.
  def write_root(slug, title: nil, tags: [], synopsis: :unset, kind: :unset)
    fm = { "title" => (title || slug.split("/").last), "tags" => tags, "created" => "2026-01-01", "updated" => "2026-01-01" }
    fm["synopsis"] = synopsis unless synopsis == :unset
    fm["kind"] = kind unless kind == :unset
    path = Trellis::Config.roots_dir.join("#{slug}.md")
    path.dirname.mkpath
    path.write(<<~MD)
      ---
      #{YAML.dump(fm).delete_prefix("---\n").strip}
      ---

      ## Context

      ## Log
    MD
    path
  end

  # Write an artifact (FTS-only long-form doc). slug may contain "/" for the
  # YYYY/MM sharding, so create parent dirs.
  def write_artifact(slug, title: nil, body: "content", tags: [])
    fm = { "title" => (title || slug.split("/").last), "tags" => tags }
    path = Trellis::Config.artifacts_dir.join("#{slug}.md")
    path.dirname.mkpath
    path.write(<<~MD)
      ---
      #{YAML.dump(fm).delete_prefix("---\n").strip}
      ---

      #{body}
    MD
    path
  end
end
