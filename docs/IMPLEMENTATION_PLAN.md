# Implementation Plan

## Strategy

Build `vrv` as a sequence of independently verifiable milestones. The first
milestone is the Nix development and packaging foundation. Stop after it, verify
the entire toolchain interactively, and only then begin plugin behavior.

The shortest path to a useful version is:

1. Reproducible flake and loadable plugin skeleton.
2. JSON model, Git branch scope, and persistence.
3. Add/edit/delete through a normal Neovim buffer, with signs.
4. Minimal Markdown-to-clipboard export.
5. Telescope browsing, searching, editing, and deletion.
6. Navigation, branch-change behavior, and integration hardening.

The primary `<leader>ra` → annotate → `:wq` → `<leader>rE` workflow is complete
after milestone 4. Telescope and secondary navigation follow once that vertical
slice works.

## Non-negotiable implementation boundaries

- Implement only [FEATURES.md](FEATURES.md), not feature parity with the old
  plugin.
- Keep JSON as the single durable model. UI modules operate through the store;
  exporters receive decoded model data.
- Keep branch filtering inside the query/store boundary so signs, navigation,
  Telescope, and export cannot accidentally show another branch.
- Keep formatting pure and testable without Telescope or editor windows.
- Do not introduce configuration, compatibility layers, migration, stale
  detection, multi-instance protection, or GitHub-specific metadata.
- Make each milestone pass `nix flake check -L` before proceeding.

## Milestone 1 — Flake, dev shell, packaging, and smoke test

### Goal

Prove that a clean checkout can enter a pinned environment, load the local
plugin with its runtime dependencies, run headless checks, build a distributable
plugin derivation, and be consumed by another flake.

No product behavior beyond `require("vrv")` successfully loading belongs in this
milestone.

### Files

- `flake.nix`
- `flake.lock`
- `.envrc`
- `.gitignore`
- `.stylua.toml`
- `plugin/vrv.lua`
- `lua/vrv/init.lua`
- `tests/minimal_init.lua`
- `tests/smoke_spec.lua`
- A small test runner or task entry point if needed.

### Flake inputs and compatibility

- Pin one `nixpkgs` input in `flake.lock`.
- Obtain Neovim, Telescope, Plenary, and development tools from that pinned
  nixpkgs revision unless a package is unavailable or incompatible.
- Pin a Neovim/Telescope/Plenary combination that satisfies Telescope's current
  requirements. At plan time, Telescope documents Neovim 0.11.7+ and Plenary as
  required.
- Support the common Linux and Darwin systems through `nixpkgs.lib.genAttrs` or
  an equivalently small mechanism. Avoid adding a flake framework solely to
  generate systems.

### Flake outputs

Expose:

- `packages.<system>.vrv-nvim`: the packaged plugin.
- `packages.<system>.default`: alias of `vrv-nvim`.
- `overlays.default`: adds `vrv-nvim` to a downstream package set.
- `devShells.<system>.default`: the complete development environment.
- `checks.<system>.package`: builds the plugin package.
- `checks.<system>.smoke`: launches headless Neovim and requires `vrv`.
- `checks.<system>.tests`: runs the Neovim test suite.
- `checks.<system>.format`: checks Lua and Nix formatting without modifying the
  tree.
- A development Neovim package/app or test launcher whose runtime path includes
  Telescope, Plenary, and the working checkout.

The downstream overlay must not depend on the consumer reproducing vrv's dev
shell. Its plugin package should declare or expose the Telescope and Plenary
runtime relationship clearly enough for the personal Neovim flake to install
the complete set.

### Development shell

Include pinned versions of:

- Neovim.
- Git.
- Telescope and Plenary on the development Neovim runtime path.
- ripgrep for Telescope search behavior.
- StyLua.
- A Nix formatter.
- Lua language server.
- The chosen headless Lua/Neovim test runner.
- Any lightweight Nix lint/check tools actually wired into `flake check`.

Do not add unused tools speculatively.

`.envrc` contains `use flake`. After the one-time `direnv allow`, entering the
repository should activate the same default development shell as `nix develop`.

### Minimal plugin skeleton

- `plugin/vrv.lua` guards against duplicate loading and requires a supported
  Neovim version.
- `lua/vrv/init.lua` returns a module table with an idempotent `setup()`.
- Do not register final commands or mappings yet unless needed by the smoke
  test.
- The smoke test verifies that the module loads in the packaged environment and
  from the working checkout.

### Verification gate

Run and record the results of:

```sh
nix flake show
nix flake check -L
nix build .#vrv-nvim
nix develop -c nvim --headless -u tests/minimal_init.lua \
  -c 'lua require("vrv").setup()' -c qa
direnv exec . nvim --headless -u tests/minimal_init.lua \
  -c 'lua require("vrv").setup()' -c qa
```

Also verify a small downstream consumer expression/fixture can apply
`overlays.default`, resolve `vrv-nvim`, and construct a Neovim environment with
vrv, Telescope, and Plenary.

Because this repository is a Git flake, stage newly created source files before
running these checks so Nix includes them in the flake source. A commit is not
required for the intermediate verification.

### Exit criteria

- `flake.lock` is committed and a clean checkout does not fetch unpinned project
  dependencies outside the normal Nix substitute/build process.
- Every flake output evaluates for the declared systems.
- All checks pass on the current system.
- `nix build .#vrv-nvim` produces a valid Neovim plugin tree.
- Both `nix develop` and direnv can run the headless smoke test.
- The development launcher can open Neovim and run `:checkhealth telescope`
  without a missing Plenary/runtime error.
- The downstream-consumer check succeeds.
- Stop here and review the flake before implementing milestone 2.

## Milestone 2 — Core model, Git scope, and JSON store

### Goal

Create a tested persistence layer with no UI dependency.

### Proposed modules

- `lua/vrv/git.lua`: project root and current symbolic branch.
- `lua/vrv/model.lua`: schema validation and annotation construction.
- `lua/vrv/store.lua`: load, query, add, update, delete, and atomic save.
- `lua/vrv/context.lua`: current file/range and three-line snippet capture.
- `lua/vrv/util.lua`: narrow path/JSON helpers shared by those modules.

### Version 1 JSON shape

Use the smallest model that satisfies the specification:

```json
{
  "version": 1,
  "annotations": [
    {
      "id": "stable-unique-id",
      "branch": "feature/example",
      "file": "lua/vrv/store.lua",
      "start_line": 42,
      "end_line": 42,
      "snippet_start": 39,
      "snippet": [
        "39: context above",
        "40: context above",
        "41: context above",
        "42: annotated source line",
        "43: context below",
        "44: context below",
        "45: context below"
      ],
      "text": "The review comment."
    }
  ]
}
```

Exact ID representation can be chosen during implementation, but it must remain
stable, collision-resistant within one store, and independent of timestamps for
sorting correctness.

### Behavior

- Resolve the Git root from the source buffer.
- Read the current symbolic branch for every top-level user action; do not rely
  indefinitely on a setup-time cache.
- Reject add/browse/export cleanly under detached `HEAD`.
- Store all branches in `.cache/vrv/annotations.json`.
- Return current-branch annotations from one canonical query.
- Preserve other branches on every write.
- Write JSON atomically through a sibling temporary file and rename.
- On malformed or unsupported JSON, report the problem and do not overwrite the
  file.
- Append `/.cache/vrv/annotations.json` to `.gitignore` once.
- Assume one Neovim instance per repository; add no locks or merge logic.
- Support live-buffer snippet capture at file boundaries and for multiline
  visual ranges.

### Tests

- Model validation accepts the exact v1 shape and rejects missing/wrong fields.
- JSON round trip preserves Unicode, multiline text, branch names containing
  slashes, and numbered snippets.
- Current-branch filtering never returns another branch.
- Add/update/delete preserve unrelated annotations and branches.
- Atomic save leaves the previous file intact when encoding or writing fails.
- Malformed and unsupported stores are not replaced.
- `.gitignore` update is idempotent.
- Context capture handles first line, last line, short files, unsaved changes,
  and visual ranges.
- Git tests use temporary repositories for normal, unborn, and detached branch
  states.

### Exit criteria

- All store behavior is exercised headlessly.
- No module in this milestone requires Telescope or creates a window.
- `nix flake check -L` passes.

## Milestone 3 — Annotation editor, commands, mappings, and signs

### Goal

Implement adding, editing, and deleting annotations using ordinary Neovim
buffers.

### Proposed modules

- `lua/vrv/editor.lua`: annotation-buffer creation and write lifecycle.
- `lua/vrv/signs.lua`: branch-filtered extmarks and in-session position sync.
- `lua/vrv/init.lua`: public actions and orchestration.
- `plugin/vrv.lua`: fixed commands and mappings.

### Behavior

- Register `:Vrv add`, `:Vrv edit`, and `:Vrv delete`.
- Register `<leader>ra`, `<leader>re`, and `<leader>rd`.
- Capture cursor or visual line range before leaving the source window.
- Open a full-width horizontal split with a named Markdown `acwrite` buffer.
- Keep source association in buffer-local Lua state, not editable lines.
- New buffers start empty; edits start with existing plain text.
- `:w` trims/validates and persists without closing.
- `:wq` persists and closes only the annotation split.
- `:q!` discards unsaved text.
- Empty new annotations are not created.
- After closing, restore focus to the source window when it still exists.
- Place one fixed sign/extmark at the annotation's starting line.
- Track in-session line drift and synchronize positions before store writes and
  export.
- Re-render signs for the current branch on buffer entry and explicit reload.
- If multiple annotations overlap the cursor, defer disambiguation to the
  Telescope milestone rather than guessing.

### Tests

- Normal and visual add capture the correct range and context.
- `:w`, `:wq`, `:q!`, empty text, and repeated writes have the specified
  effects.
- Edit changes only text.
- Delete removes JSON state and extmark.
- Branch-filtered signs render only on matching files.
- Extmark movement updates both start and end lines by the same drift.
- Setup is idempotent and does not duplicate commands, mappings, or autocmds.

### Exit criteria

- The complete add/edit/delete loop works manually inside `nix develop`.
- Closing the annotation editor never closes the user's source window or exits
  Neovim.
- `nix flake check -L` passes.

## Milestone 4 — Minimal Markdown export

### Goal

Complete the primary workflow by exporting current-branch annotations to the
system clipboard.

### Proposed module

- `lua/vrv/export.lua`: pure Markdown transformation plus a thin clipboard
  adapter.

### Behavior

- Register `:Vrv export` and `<leader>rE`.
- Synchronize open-buffer extmarks before reading export data.
- Query only current-branch annotations.
- Sort by file, start line, and stable ID.
- Emit only `## @file`, `### file — line/range`, fenced numbered context, and
  annotation text.
- Emit no title, date, introduction, preamble, summary, or counts.
- Derive fence language from the stored file path.
- Copy to the `+` register only after formatting succeeds.
- Do not change the clipboard when there are no annotations.
- Never mutate or clear annotations during export.

### Tests

- Snapshot exact single-file, multi-file, multiline-range, Unicode, and unknown
  extension output.
- Assert deterministic order independent of JSON array order.
- Assert there is no header, summary, preamble, type, or symbol text.
- Assert branch filtering and empty-export clipboard behavior.

### Exit criteria

- The primary workflow from add through clipboard export works end to end.
- Pasting the clipboard produces exactly the approved minimal layout.
- `nix flake check -L` passes.

## Milestone 5 — Telescope browser

### Goal

Provide the current-branch search and management view.

### Proposed module

- `lua/vrv/picker.lua`: one purpose-built Telescope picker.

### Behavior

- Register `:Vrv browse` and `<leader>rf`.
- Build entries from the canonical current-branch store query.
- Match file path, annotation text, and captured source text.
- Display file, line/range, and compact comment text.
- Preview the source file at the stored line without stale classification or
  re-anchoring.
- `<CR>` jumps to the source location.
- `<C-d>` deletes immediately, saves JSON, removes the sign, and refreshes the
  picker without closing it.
- `<C-e>` closes/suspends the picker as needed and opens the selected annotation
  in the normal edit split.
- A picker filtered to annotations overlapping the cursor handles edit/delete
  disambiguation.

### Tests

- Entry construction and ordinal text contain all searchable fields.
- Only current-branch annotations become entries.
- Delete refreshes results and cannot delete an adjacent ID accidentally.
- Edit passes the selected stable ID to the editor.
- Jump uses the stored file and line.
- UI behavior receives one manual smoke pass because floating-window interaction
  is brittle to assert entirely in headless tests.

### Exit criteria

- Search, preview, jump, edit, and repeated `<C-d>` deletion work in the pinned
  development Neovim.
- Telescope reports no missing Plenary/runtime dependency.
- `nix flake check -L` passes.

## Milestone 6 — Navigation, reload, and branch lifecycle

### Goal

Finish secondary workflows and make branch changes predictable.

### Behavior

- Register `:Vrv next`, `:Vrv prev`, `:Vrv reload`, `]r`, and `[r`.
- Sort navigation by file, line, and ID and wrap in both directions.
- Open the target file and move to the stored line.
- Re-read the current branch on actions and on a small set of lifecycle events,
  such as `BufEnter`, `FocusGained`, and `DirChanged`.
- When the branch key changes, clear old extmarks and render the new branch's
  annotations.
- Reload replaces in-memory state from valid JSON and redraws signs.
- Missing files or out-of-range lines produce a normal error and leave JSON
  untouched; do not classify or repair them.

### Tests

- Next/previous ordering, wrapping, empty state, and cross-file jumps.
- Temporary Git repository branch switches change signs, browser data, and
  export data.
- Explicit reload reflects a valid external file edit.
- Detached `HEAD` refuses branch-scoped operations without corrupting state.
- Autocmd registration remains idempotent.

### Exit criteria

- Switching branches in the same repository visibly swaps annotation state.
- Navigation and reload work from fixed mappings and commands.
- `nix flake check -L` passes.

## Milestone 7 — Final integration and downstream verification

### Goal

Validate the completed initial feature set as both a checkout and a flake input.

### Work

- Run the full headless suite from a clean checkout.
- Run Lua and Nix formatting checks.
- Build every declared package/check for the local system.
- Re-run the downstream flake consumer with the completed plugin.
- Exercise the complete workflow manually in a temporary Git repository with at
  least two branches and two source files.
- Confirm `.gitignore` behavior, JSON contents, signs, branch isolation,
  Telescope deletion, normal-buffer editing, and exact clipboard output.
- Remove unused dependencies and any framework code not required by
  [FEATURES.md](FEATURES.md).
- Add only the minimal installation example needed by the personal Neovim flake;
  broad end-user documentation remains out of scope.

### Definition of done

- Every feature in [FEATURES.md](FEATURES.md) has an automated test or a named
  manual acceptance check.
- `nix flake check -L` passes from a clean checkout.
- `nix build .#vrv-nvim` succeeds.
- direnv activates the same toolchain as `nix develop`.
- The downstream personal-flake consumption path works without copying vrv's
  internal development configuration.
- No functionality listed as out of scope has been introduced.

## Deferred work

The GitHub CLI transformation begins only after the initial definition of done.
It will use the existing branch, file, line/range, text, and snippet fields and
will support only ordinary non-deleted diff lines. It does not affect the
milestones above.
