module Trellis
  # Durability layer — every write boundary commits the vault so state is
  # never more than one action from safe. Messages are derived, not supplied:
  # the app knows the action + slug + content, so agents never author them.
  module Git
    module_function

    # Stage everything and commit. No-op (returns false) when the vault isn't a
    # git repo or nothing changed — callers don't need to care either way.
    def commit(message)
      root = Config.vault.to_s
      return false unless repo?(root)

      run(root, "add", "-A")
      run(root, "commit", "-q", "-m", message)
    end

    def repo?(root)
      run(root, "rev-parse", "--git-dir")
    end

    def init(root)
      run(root, "init", "-q")
    end

    def run(root, *args)
      system("git", "-C", root, *args, out: File::NULL, err: File::NULL)
    end

    # First line, whitespace-collapsed, truncated — keeps commit subjects short.
    def summarize(text, limit = 60)
      line = text.to_s.strip.split("\n").first.to_s.gsub(/\s+/, " ")
      line.length > limit ? "#{line[0, limit - 1]}…" : line
    end
  end
end
