require "date"
require "yaml"
require "json"
require "pathname"

# The vault is UTF-8 Markdown, full stop. Ruby's file-read default otherwise
# follows the process locale (LANG/LC_ALL) — GUI apps like Claude Desktop spawn
# subprocesses without one, which falls back to US-ASCII and raises
# "ArgumentError: invalid byte sequence in US-ASCII" the moment a file has an
# em dash, curly quote, or any non-ASCII byte. Force it so vault reads/writes
# never depend on the caller's environment.
Encoding.default_external = Encoding::UTF_8

require_relative "trellis/config"
require_relative "trellis/arc"
require_relative "trellis/index"
require_relative "trellis/store"
require_relative "trellis/git"

module Trellis
  VERSION = "0.1.0"
end
