# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0]

Initial release, extracted from mnemodoc-server 1.5.1.

### Added

- **`Watch::Inotify`** (Linux), **`Watch::FSEvents`** (macOS) and **`Watch::Poll`**
  backends behind `Watch::Backend`; `Watch::Unavailable` when a native one cannot run.
- **`Watch::Filter`** — roots, hidden entries and exclusion globs, plus a
  consumer predicate; prunes excluded trees before listing them.
- **`Watch::Coalescer`** — folds the events of one path within a window;
  `OnClose::Drop` (default) or `OnClose::Drain` on shutdown.
- **`Watch::Watcher`** — `Auto` / `Native` / `Poll` backend selection, fallback
  to polling, restart after a crash, and six callbacks.
- The FSEvents C shim is compiled by a macro at Crystal compile time.
