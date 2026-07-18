require_relative "test_helper"

# GUI-launched processes (e.g. Claude Desktop spawning the MCP server) have no
# LANG/LC_ALL, so Ruby's file-read default falls back to US-ASCII and raises
# "invalid byte sequence in US-ASCII" the moment a vault file has an em dash or
# curly quote. lib/trellis.rb forces Encoding.default_external = UTF-8 at load
# time so vault reads never depend on the caller's locale.
class EncodingTest < Minitest::Test
  include VaultTest

  def test_default_external_is_utf8
    assert_equal Encoding::UTF_8, Encoding.default_external
  end

  def test_reads_non_ascii_content_without_locale_env
    path = write_arc("smart-quotes", title: "Dana’s Estate — Plan")
    path.write(path.read + "\n— an em dash and ’ a curly quote in the body\n")

    arc = Trellis::Arc.new(path)

    assert_equal "Dana’s Estate — Plan", arc.title
    assert_includes arc.body, "— an em dash"
  end
end
