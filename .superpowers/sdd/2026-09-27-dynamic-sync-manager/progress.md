# SDD ledger — plan: docs/superpowers/plans/2026-09-27-dynamic-sync-manager.md

Ruling: use inline execution and static validation only — user approved native execution and explicitly instructed not to add/run tests; shared job configuration makes file-by-file parallel implementation risky.

Provider refinement: destination form lists existing rclone remotes using `rclone listremotes --json`, exposes only `name` and `type`, and supports explicit refresh. Adding provider credentials remains the native rclone flow.

Implementation complete: private sync configuration and runner integration, per-job status/baseline, global safety filters, Quickshell manager/form and rclone provider selector, documentation/version metadata. Source paths entered as `~/...` are expanded before canonicalization. No synchronization or baseline recreation was run.

Static validation passed: `bash -n src/omarchy-backup.sh`, jq 1.8.2 syntax/behavior check for destination-overlap validation, `jq empty omarchy-plugin/manifest.json`, `omarchy plugin validate omarchy-plugin`, and `git diff --check`. `qmllint` and `shellcheck` are not installed; plugin validator checks the manifest only. No tests were run per user instruction.

Install outcome: plugin files were copied, the Omarchy plugin was rescanned/enabled, the script symlink points to this checkout, and the two-hour user timer remains active. Installer surfaced a pre-existing config validation bug: the control-character regex escaped Unicode twice and rejected normal values. Fixed it and verified the existing private config matches the schema; no sync/resync was started.

Usability refinement: added a persistent `+ Novo sync` action to the panel header; made a first-run configuration empty unless the legacy `Filen:` remote is already configured; removed the install-time Filen requirement and automatic Filen Desktop credential copy; generalized baseline labels; rewrote README for provider-neutral setup. The repository itself is currently private on GitHub, so README changes do not make it cloneable to other users.

Validation for refinement passed: `bash -n` on both shell scripts, manifest JSON validation, `omarchy plugin validate`, and `git diff --check`. Installed plugin contains the new header action and Omarchy reports it enabled. `qmllint` and `shellcheck` remain unavailable; no automated tests or syncs were run.

Follow-up after user reported the control was still not visible: moved the add action to a full-width row immediately below the panel title, fixed the form delegate's missing required `index` property (the running shell log had reported `ReferenceError: index is not defined`), reinstalled, and restarted Omarchy shell. New shell instance loaded with no QML `ReferenceError`; installed QML contains the wide add button.

Latest UI fix from screenshots: form now has an always-visible close action plus Escape handlers for focused text inputs; the ScrollView uses the Omarchy pattern (`availableWidth` and an interactive content item bound to overflow); long footer labels are constrained/elided; local Omarchy/favorites snapshot status and storage path are shown near the top before the sync manager. Reinstalled/restarted again, confirmed installed QML matches source and active Quickshell instance is present. Shell syntax, manifest/plugin validation, and diff checks pass; runtime log on startup has no QML errors. No syncs were run.

Pre-flight: job storage produces config/status interfaces consumed by runner and QML; runner produces per-job result/baseline semantics consumed by QML; README documents the resulting user-visible behavior.

CI follow-up (2026-09-28): the user explicitly requested an anti-regression CI strategy. Added isolated Bash regression checks for status parsing, provider-neutral read-only verification, copy flags, empty favorites, GTK URL redaction, uppercase secret detection, snapshot path traversal, and private sync configuration writes. Added GitHub Actions checks for Bash syntax, ShellCheck errors, the regression script, and Gitleaks. The tests use temporary HOME/config/state paths and a fake rclone; they do not contact a provider. During test development, fixed two defects the earlier review missed: the secret scanner now matches environment assignments like `AWS_SECRET_ACCESS_KEY=value`, and the rclone runner creates its log before counting lines. Eight regression checks pass locally.
