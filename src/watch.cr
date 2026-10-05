# Native file watching: inotify on Linux, FSEvents on macOS, polling elsewhere.
module Watch
  VERSION = "0.1.0"
end

require "./watch/event"
require "./watch/backend"
require "./watch/filter"
require "./watch/entries"
require "./watch/poll"
require "./watch/coalescer"
require "./watch/inotify"
require "./watch/fsevents"
require "./watch/watcher"
