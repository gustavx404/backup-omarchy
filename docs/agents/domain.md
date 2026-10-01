# Domain docs

## Before exploring

- Read the root `CONTEXT.md`, or `CONTEXT-MAP.md` if one exists.
- Read relevant decisions in `docs/adr/`.
- If these files do not exist, continue without flagging their absence. Create them when domain terms or decisions are resolved.

## Layout

This is a single-context repo:

- `CONTEXT.md` holds the project vocabulary and domain model.
- `docs/adr/` holds architecture decisions.
- Do not create a context map unless the repo grows into multiple distinct contexts.

Use terms from `CONTEXT.md` in issues, tests, and design proposals. If a needed term is missing, note the gap. Surface conflicts with existing ADRs instead of silently overriding them.
