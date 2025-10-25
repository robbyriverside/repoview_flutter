# Phase 1 – RVG Core & File Sync

## What I Found
- RepoView’s value depends on accurate `.repoview.rvg` persistence and tight coupling with the filesystem.
- Failure cases (missing files, renames, divergent RVG versions) were not yet broken down into actionable tasks.

## What I Did
- Expanded the plan to include migration tooling, backups, and validation paths for RVG files.
- Added explicit steps for bidirectional sync, default RVG generation, and a comprehensive test strategy to ensure resilience.
- Implemented the first persistence layer (`lib/rvg/rvg_persistence_service.dart`) and wired `lib/main.dart` to load/save an RVG document, update edge connections, and persist node movement back to disk.
- Bootstrapped a demo workspace in the system temp directory and ensured a `.repoview.rvg` file is created alongside seed content (`lib/main.dart:60`).
- Added `RvgSyncService` (`lib/rvg/rvg_sync_service.dart`) plus a sync command in the UI to reconcile RVG nodes with the filesystem, creating/removing nodes for files and folders while preserving custom graph elements.
- Added a filesystem watcher so changes in the workspace flow back into the graph automatically with debounced syncing (`lib/main.dart:233`).
- Introduced automatic RVG backups prior to overwriting documents to protect user edits (`lib/rvg/rvg_persistence_service.dart:40`).
- Covered the sync service with unit tests exercising add/remove scenarios on real temp directories (`test/rvg_sync_service_test.dart`).
