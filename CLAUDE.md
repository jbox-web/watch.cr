# CLAUDE.md

Guidance for Claude Code (and other agents) working in this repository.

## What this is

`watch` is a native file-watching shard for Crystal: inotify on Linux, FSEvents
on macOS, polling elsewhere, a pruning path filter, event coalescing and backend
selection with fallback. It was extracted from `mnemodoc-server`, which is its
first consumer — any change here must keep that consumer's behaviour, log lines
included.

## Working agreements

- **Memory is not a source.** Do not act or assert from training memory or prior
  context. Anything not read from a file or a cited source in the current turn is
  off-limits as the basis for a change. When unsure, read first or say so.
- Comments go **above** the code, never inline.
- Code, comments, and test descriptions are in **English**.
- Named arguments on non-trivial calls.
- **After any code change, run the full `mise dev:check`** (build-check + ameba +
  spec). Never rely on a single sub-task.

## Hard constraints

- **Zero runtime dependencies.** Crystal standard library and libc only, plus
  CoreServices on macOS.
- What a consumer must see goes through the `Watcher` callbacks. The shard
  logs above `debug` **only** from a callback left at its default (README,
  "Callbacks"); a consumer that sets all six gets no log line from the shard
  above `debug` — mnemodoc relies on it to keep its own log lines unchanged.
- The FSEvents shim is compiled by the macro at the top of
  `src/watch/fsevents.cr`, behind `flag?(:darwin)`. Never add a build step a
  consumer would have to run.
- `0.x`: the public API may still change in a minor release; say so in the
  CHANGELOG when it does.

## Development commands

```sh
mise dev:deps    # shards install
mise dev:spec    # run specs (Spectator)
mise dev:ameba   # static analysis
mise dev:format  # format src/, spec/
mise dev:check   # build-check + ameba + spec
mise dev:build   # compile-check the library (no codegen)
```

Run a single spec file: `crystal spec spec/watch/filter_spec.cr`.

`inotify_spec` compiles on Linux only and `fsevents_spec` on macOS only. To run
the Linux side from macOS, mask the host's `lib/` **and** `bin/` — ameba's
postinstall writes its binary into `bin/`:

```sh
docker run --rm -v "$PWD":/src -v /src/lib -v /src/bin -w /src crystallang/crystal:1.20.3 \
  sh -c 'shards install && crystal spec spec/watch/'
```

## Architecture

```
src/watch.cr                 Entry point: Watch::VERSION + requires
src/watch/
  event.cr                   Watch::Event (path + Added/Changed/Deleted)
  backend.cr                 Watch::Backend (run until stop closes) + Watch::Unavailable
  filter.cr                  Watch::Filter — roots, consumer predicate, hidden entries, exclusions; memoised descend?
  entries.cr                 d_type directory listing shared by Poll and Inotify
  poll.cr                    Watch::Poll — polling backend
  coalescer.cr               Watch::Coalescer — per-path folding window; OnClose Drop/Drain
  inotify.cr                 Watch::Inotify (Linux)
  fsevents.cr                Watch::FSEvents (macOS) + the macro compiling the shim
  fsevents_shim.c            FSEvents bridge: callback on a dispatch queue writes records into a pipe
  watcher.cr                 Watch::Mode, Watch.native_backend, Watch.backend_name, Watch::Watcher
```

Specs mirror the source under `spec/watch/`; `spec/spec_helper.cr` provides
`md_filter`, the Markdown-only filter the backend specs share.
