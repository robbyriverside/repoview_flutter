# Phase 3 – File-Type Visuals

## What I Found
- RepoView’s promise of “a visual for every file” requires a modular rendering strategy with lazy asset management.
- Edge cases like referenced files (shift-drag) and large media previews were not explicitly addressed.

## What I Did
- Established the preview pipeline architecture so renderers can request cached assets or text snippets on demand.
- Implemented a reusable preview cache with image/text/markdown fetchers (`lib/services/file_preview_cache.dart`) and wired it into the graph UI for file nodes (`lib/main.dart:220`).
- Expanded sync metadata to capture file size, folder counts, and sample children enabling richer folder cards (`lib/rvg/rvg_sync_service.dart:58`).
- Refined rectangular renderers to surface previews, size info, and folder chips, plus added helper utilities for formatting preview snippets (`lib/main.dart:610`, `lib/main.dart:954`).
- Resolved layout overflow by making previews and metadata layout-aware, adding flexible containers so README.md and notes.txt stay within their cards (`lib/main.dart:900`).
