module Watch
  # Decides which paths a watch backend reports and which directories it
  # descends into: the roots, hidden entries and exclusions are its own rules,
  # the rest is the consumer's predicate. It is the only gate between a backend
  # and the consumer, so whatever it lets through is delivered.
  class Filter
    # Three names made of a private-use character no exclude pattern spells
    # out, so only a wildcard can match them: one short, one long, one nested.
    # A pattern matching all three matches every descendant of a directory,
    # whatever its name and depth. (A NUL would be the natural choice, but
    # File.match? refuses a string containing one.)
    PRUNE_PROBES = {"\u{E000}", "\u{E000}" * 8, "\u{E000}/\u{E000}"}

    getter roots : Array(String)
    @exclude : Array(String)
    @accept : Event -> Bool
    @descend = {} of String => Bool

    # *roots* are the trees to watch; a root that is not a directory is a file
    # watched on its own. *accept* is the consumer's rule for a path that is
    # under a root — keep it cheap: the poll backend asks it of every file of
    # the tree on every pass.
    def initialize(roots : Enumerable(String), exclude : Enumerable(String) = [] of String, &accept : Event -> Bool)
      # Without a trailing slash: `paths:` entries are routinely written
      # `doc/`, File.expand_path keeps the slash, and every backend builds
      # its event paths from these roots — FSEvents by concatenation, which
      # turned `doc/` into `doc//guide.md`, a path the index never holds, so
      # deletions were never applied.
      @roots = roots.map { |root| File.expand_path(root) }
        .map { |root| root == "/" ? root : root.rstrip('/') }.uniq!
      @exclude = exclude.to_a
      @accept = accept
    end

    # A filter that accepts every path under its roots that is neither hidden
    # nor excluded.
    def self.new(roots : Enumerable(String), exclude : Enumerable(String) = [] of String)
      new(roots, exclude) { |_event| true }
    end

    # True when the event should reach the consumer.
    #
    # Cheapest test first: a poll pass asks this of every file in the tree.
    # The consumer's predicate runs before the exclusion globs because it
    # usually holds the cheapest test (an extension lookup), and the globs
    # cost far more.
    def accept?(event : Event) : Bool
      path = event.path
      return false unless under_root?(path)
      return false unless @accept.call(event)
      return false if hidden?(path)

      !excluded?(path)
    end

    # True when a backend should list or watch *dir*. False only when every
    # possible descendant is excluded; a narrower exclusion still descends and
    # leaves the per-file check to #accept?.
    #
    # Memoised: the answer depends on the path and the configuration alone,
    # and a poll pass asks it of every directory of the tree every second.
    def descend?(dir : String) : Bool
      @descend.put_if_absent(dir) do
        !hidden?(dir) && @exclude.none? do |pattern|
          PRUNE_PROBES.all? { |probe| File.match?(pattern, File.join(dir, probe)) }
        end
      end
    end

    # The longest configured root containing *path*, or nil. Longest, so a
    # file under two nested roots is attributed to one of them only.
    def root_for(path : String) : String?
      @roots.select { |root| within?(path, root) }.max_by?(&.size)
    end

    # True when a component below the root containing *path* starts with a
    # dot. The crawler globs without DotFiles, so such a file is never
    # indexed at boot — a watcher that let it through made the index flap
    # between the two. A configured root that is itself hidden (`.github/`)
    # is not affected: only what lies below it counts.
    private def hidden?(path : String) : Bool
      root = root_for(path)
      return false unless root

      path[root.size..].split('/').any?(&.starts_with?('.'))
    end

    private def under_root?(path : String) : Bool
      @roots.any? { |root| within?(path, root) }
    end

    # Component-wise: `docs` contains `docs/a.md` but not `docs-old/a.md`.
    private def within?(path : String, root : String) : Bool
      path == root || path.starts_with?(root.ends_with?('/') ? root : "#{root}/")
    end

    private def excluded?(path : String) : Bool
      @exclude.any? { |pattern| File.match?(pattern, path) }
    end
  end
end
