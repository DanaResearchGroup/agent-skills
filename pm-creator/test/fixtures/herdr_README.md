# herdr shadow-stub fixtures

JSON shapes returned by the PATH/function-shadowed `herdr` stubs in
`track_test.sh` / `reconcile_test.sh` / `run-phaseA.sh`. **Probed, not
assumed**: every shape below was captured from a real herdr and is pinned to
that version — re-probe and update this note when herdr changes.

- **Probed herdr version: `herdr 0.7.3`** (probed 2026-07-25 on the dev box).

Inventory (placeholders like `__LABEL__` are substituted by the stub via
`sed` at call time — test labels/tab ids stay inside the pm token charset,
so plain `sed` substitution is safe):

| fixture | herdr command it mimics |
|---|---|
| `herdr_tab_list.json` | `herdr tab list` (envelope: `result.tabs[]` with `tab_id`/`label`/`agent_status`/`workspace_id`) |
| `herdr_workspace_list.json` | `herdr workspace list` (envelope: `result.workspaces[]` with `workspace_id`/`label`) |
| `herdr_worktree_list.json` | `herdr worktree list` (envelope: `result.worktrees[]` with `path`/`open_workspace_id`) |
| `herdr_tab_created.json` | `herdr tab create` success |
| `herdr_tab_created_no_id.json` | `herdr tab create` success variant missing `result.tab.tab_id` |
| `herdr_tab_create_error.json` | `herdr tab create` failure (exit 1) |
| `herdr_tab_closed.json` | `herdr tab close` success |
| `herdr_agent_started.json` | `herdr agent start` success |
| `herdr_agent_start_error.json` | `herdr agent start` failure (exit 1) |

Section-specific payload VARIANTS (a hostile newline label, a ~3MB label,
per-section `api snapshot` tab arrays) are built inline by their sections but
must keep these same envelopes.

Drift check: `reconcile_test.sh` carries an OPT-IN contract section gated
behind `PM_TEST_REAL_HERDR=1` (operator-only, OFF by default — the default
suite never touches a real herdr) that asserts the promised key paths against
a live `herdr tab list` / `herdr workspace list`.
