require "spectator"
require "file_utils"

Spectator.configure do |config|
  config.randomize
  config.profile
end

require "../src/watch"

# The filter the backend specs share: Markdown files only, deletions always,
# the way a documentation indexer would configure it.
def md_filter(roots : Array(String), exclude : Array(String) = ["**/drafts/**"]) : Watch::Filter
  Watch::Filter.new(roots, exclude) do |event|
    event.kind.deleted? || File.extname(event.path) == ".md"
  end
end
