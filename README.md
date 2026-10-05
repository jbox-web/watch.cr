# watch

[![CI](https://github.com/jbox-web/watch.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/jbox-web/watch.cr/actions/workflows/ci.yml)
[![Tag](https://img.shields.io/github/v/tag/jbox-web/watch.cr?sort=semver)](https://github.com/jbox-web/watch.cr/tags)
[![Crystal](https://img.shields.io/badge/crystal-%3E%3D%201.18-black?logo=crystal)](https://crystal-lang.org)
[![License](https://img.shields.io/github/license/jbox-web/watch.cr)](LICENSE)

Native file watching for Crystal: **inotify** on Linux, **FSEvents** on macOS,
**polling** everywhere else — with a path filter that prunes before it lists,
event coalescing, and a watcher that picks a backend and falls back on its own.

Extracted from [mnemodoc-server](https://github.com/mnemodoc/mcp-server), where
it keeps a documentation index live.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  watch:
    github: jbox-web/watch.cr
    version: ~> 0.1
```

Then run `shards install`.

## Usage

```crystal
require "watch"

# Which paths to report: under the roots, not hidden, not excluded, and
# accepted by your predicate.
filter = Watch::Filter.new(["doc"], exclude: ["**/tmp/**"]) do |event|
  event.kind.deleted? || event.path.ends_with?(".md")
end

watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Auto, poll_interval: 1.second)
watcher.on_fallback { |ex| STDERR.puts "no native events (#{ex.message}), polling" }

stop = Channel(Nil).new
spawn { watcher.run(stop) { |event| puts "#{event.kind} #{event.path}" } }

# ... later: ends the watch within about a second, no file event needed.
stop.close
```

`run` blocks until `stop` is closed, and returns only once the last event handed
to the block is done with.

## The filter

`Watch::Filter.new(roots, exclude = [] of String, &predicate)`:

- **Roots** are expanded to absolute paths and held without a trailing slash. A
  root that is not a directory is a file watched on its own.
- `accept?(event)` checks, in this order: under a root (component-wise: `docs`
  does not contain `docs-old/`), your predicate, no hidden component below the
  root, no exclusion glob. The predicate runs before the globs because it
  usually holds the cheapest test — keep it cheap: the poll backend asks it of
  every file on every pass.
- `descend?(dir)` is false only when **every** possible descendant is excluded,
  so backends skip whole excluded trees without listing them.
- Deletions reach your predicate like any event: a deleted directory has no
  extension and can no longer be stat-ed, so decide what to do with it there.
- Without a block, the filter accepts everything under its roots that is
  neither hidden nor excluded.

## Backends

| Backend | Platform | How it watches |
|---|---|---|
| `Watch::Inotify` | Linux | One watch per non-excluded directory, plus each root's parent, so a root deleted and recreated (a `git checkout`) is seen again. New and moved-in directories are watched then scanned; moved-out ones are reported as one `Deleted` event and unwatched; a queue overflow triggers a full rescan. |
| `Watch::FSEvents` | macOS | One stream over every root. Paths reported resolved (`/tmp` is `/private/tmp`) are mapped back to the spelling you configured. The stream is restarted when a root appears. |
| `Watch::Poll` | anywhere | Walks the roots every interval, reading the entry type from the directory listing (no `stat` to tell a file from a directory), pruning excluded directories, and stat-ing only the files the filter would accept. |

`Watch.native_backend(filter)` returns the one for the current platform, or
raises `Watch::Unavailable` where there is none. Native backends also raise it
when the kernel refuses them — inotify's `max_user_watches` exhausted (`ENOSPC`),
an event stream that does not start.

## Modes

| Mode | Native unavailable |
|---|---|
| `Auto` (default) | `on_fallback`, then polling |
| `Native` | `on_unavailable`, then the watch ends — it never polls |
| `Poll` | the native backend is never built |

A backend that crashes is reported through `on_error` and restarted after a
one-second pause; one that returns though nobody asked it to stop goes through
`on_restart` and gets the same pause.

## Callbacks

| Callback | When |
|---|---|
| `on_start { \|backend\| }` | before each run of a backend — including a native one that then proves unavailable |
| `on_fallback { \|ex\| }` | `Auto`: native unavailable, switching to polling |
| `on_unavailable { \|ex\| }` | `Native`: native unavailable, the watch ends |
| `on_restart { \|backend\| }` | a backend returned on its own |
| `on_error { \|ex\| }` | a backend crashed |
| `on_event_error { \|event, ex\| }` | your block raised on an event; delivery goes on |

Left at their default, they log through `Log.for("watch")`. The shard writes
nothing else above `debug`. `Watch.backend_name(backend)` gives `Inotify`,
`FSEvents` or `Poll`.

## Coalescing

Events of one path within a window (`coalesce:`, 300 ms by default) fold into
one carrying the last kind seen, so one editor save — created, written, renamed
over — is one delivery. Reading and delivering run in separate fibers: a slow
block never stalls the backend.

When the watch stops, what is still pending is dropped (`on_close:
Watch::Coalescer::OnClose::Drop`, the default) — right for a consumer that
catches up at startup. `OnClose::Drain` delivers it first, oldest first.

## Build

On macOS the FSEvents bridge is a small C file, `src/watch/fsevents_shim.c`,
compiled by a macro **at Crystal compile time**: there is no build step for you
to run, but `cc` must be available and `lib/watch/src/watch/` writable. The
object is written to a temporary file and moved into place, so concurrent builds
are safe. On Linux nothing is compiled: the macro is behind `flag?(:darwin)`.

## Development

```sh
mise dev:deps    # shards install
mise dev:check   # build-check + ameba + spec
```

The inotify specs compile on Linux only and the FSEvents specs on macOS only;
the CI matrix runs both.

## License

MIT — see [LICENSE](LICENSE).
