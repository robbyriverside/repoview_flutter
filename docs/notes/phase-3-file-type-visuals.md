# Phase 3 – File-Type Visuals

## What I Found
- RepoView’s promise of “a visual for every file” requires a modular rendering strategy with lazy asset management.
- Edge cases like referenced files (shift-drag) and large media previews were not explicitly addressed.

## What I Did
- Added plan items for a pluggable renderer interface, caching strategy, and provenance indicators for external references.
- Included quick-action hooks so each file node can expose context-aware operations (open, duplicate, reveal).
