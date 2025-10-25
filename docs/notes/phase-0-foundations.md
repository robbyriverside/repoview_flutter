# Phase 0 – Foundations

## What I Found
- `docs/repoview.md` frames RepoView as a desktop tool that mirrors filesystem changes into RVG diagrams and aspires to rich per-file visuals plus AI-assisted layout.
- Saw the roadmap lacked an upfront alignment pass: success metrics, target platforms, and schema guardrails were undefined before implementation.

## What I Did
- Updated `docs/plan.md` Phase 0 tasks to require a product charter, measurable goals, and an early desktop platform decision.
- Added items covering RVG domain modeling, schema evolution strategy, and an integration audit spanning filesystem, Git, and AI touchpoints.
- Introduced foundational code for the RVG domain: `lib/rvg/rvg_types.dart` captures visual categories and `lib/rvg/rvg_models.dart` defines immutable RVG node/document objects with JSON serialization.
- Recorded these learnings here so the team can track Phase 0 outcomes during reviews.
