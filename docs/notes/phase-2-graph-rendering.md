# Phase 2 – Graph Rendering & Interaction

## What I Found
- The live prototype already shows interactive nodes and arrows, but the plan needed to codify reusable rendering patterns.
- Interaction requirements (selection, drag, connection updates) must scale to diverse node shapes and sizes.

## What I Did
- Documented tasks for building an extensible render pipeline, robust hit-testing, and polished visuals (drop shadows, theming).
- Captured the need for undo/redo support and real-time edge updates to keep the desktop tool responsive and predictable.
- Reworked rectangular node rendering to support folder, file, note, and external visuals with tailored colors/icons (`lib/main.dart:598`).
- Added undo/redo management with toolbar controls plus drag-aware history capture so repositioning and wiring changes are reversible (`lib/main.dart:48`, `lib/main.dart:432`, `lib/main.dart:1186`).
- Debounced drag persistence and selection logic remain smooth while new renderers preserve anchor calculations for edge routing.
