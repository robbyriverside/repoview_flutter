# RepoView Desktop Tool Plan

## Phase 0 – Foundations
- [ ] Establish project charter, success criteria, and v0.1.0 feature scope aligned with docs/repoview.md vision.
- [ ] Choose target desktop stack (Flutter desktop, Electron, etc.), confirm multi-platform requirements, and set up CI basics.
- [ ] Define core domain model for RVG (nodes, shapes, connections, metadata) and draft schema evolution strategy.
- [ ] Audit required integrations (filesystem monitoring, Git, drag-and-drop, AI formatting services) and document technical constraints.

## Phase 1 – RVG Core & File Sync
- [ ] Implement RVG persistence service (load/save .repoview.rvg, versioning, validation).
- [ ] Build schema migration utilities to convert older RVG files safely, including backup/rollback.
- [ ] Implement bidirectional sync engine between RVG graph and filesystem (watchers, change batching, conflict resolution rules).
- [ ] Add initial repo bootstrap workflow: detect missing RVG, generate default layout, register metadata in project root.
- [ ] Write unit/integration tests covering load/save/sync edge cases (missing files, rename, large trees).

## Phase 2 – Graph Rendering & Interaction
- [ ] Build render pipeline for nodes and edges with extensible shape system (rectangles, circles, folders, files).
- [ ] Implement hit-testing, selection, and drag mechanics; ensure connections follow nodes in real time.
- [ ] Add connection management UX (click-to-link/unlink, directional arrows, double links).
- [ ] Support drop shadows, theming, and responsive layout; design for performance with large graphs.
- [ ] Introduce undo/redo stack for node positioning and connection edits.

## Phase 3 – File-Type Visuals
- [ ] Catalog file-type visualizations: images, text previews, code summaries, README markdown, folders as tree widgets.
- [ ] Create pluggable renderer interface so each file type defines its own widget, metadata, and exposes named “views.”
- [ ] Implement lazy-loading and caching for heavy assets (large images, markdown rendering) with configurable view limits.
- [ ] Support external file references (shift-drag) alongside imported copies; reflect path provenance in UI.
- [ ] Expose quick actions (open in editor, reveal in finder, duplicate) per node and add context menu to switch available views.
- [ ] Persist per-node view preference and allow double-click to cycle through view variants; open oversized views in auxiliary overlay windows.

## Phase 4 – Repo Integration & Collaboration
- [ ] Integrate with Git status (untracked/modified indicators, branch, commit history overlays).
- [ ] Provide Git actions (stage, commit, diff) directly from node context menus when repo is detected.
- [ ] Sync with remote providers (GitHub, Azure DevOps) for metadata and optional cloud backup of RVG files.
- [ ] Implement multi-user merge helpers for RVG JSON (visual diff, conflict resolution UI).
- [ ] Add presence or change-feed for collaborative editing roadmap (initially read-only indicators).

## Phase 5 – Automation & Intelligence
- [ ] Develop layout formatters (grid, mind map, orthogonal) with configurable parameters.
- [ ] Integrate AI assistants for auto-tagging nodes, generating summaries, proposing layouts.
- [ ] Support scripted automations (e.g., create view for new feature branch) via plugin API.
- [ ] Provide templating system for custom RVG presets (architecture diagrams, kanban boards).
- [ ] Implement analytics/telemetry pipeline respecting privacy settings.

## Phase 6 – Packaging & Release
- [ ] Configure cross-platform builds (macOS, Windows, Linux) with code-signing, auto-update strategy.
- [ ] Draft onboarding flow: open folder, import existing RVG, create new, sample projects.
- [ ] Document user guides, CLI usage (if any), and troubleshooting for sync/Git issues.
- [ ] Establish QA pipeline (manual test matrix, automated UI tests, performance benchmarks).
- [ ] Prepare marketing/demo materials and schedule beta feedback cycles.
