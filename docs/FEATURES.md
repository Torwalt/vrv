# Goal Features

## Status

This is the goal specification for the rewrite. The plugin is a focused personal
tool, so the first version optimizes one review workflow rather than providing a
general-purpose framework.

The old plugin's complete capability inventory is preserved in
[`PREVIOUS.md`](PREVIOUS.md). Features not selected here are not implied goals.

## Core principles

1. Adding a review note must be nearly frictionless.
2. An annotation is plain text. It has no issue/note/suggestion type.
3. JSON is the durable source of truth.
4. Markdown and future GitHub review output are pure transformations of the
   stored annotations.
5. Annotations are isolated by Git branch.
6. Annotation text is edited with normal Neovim behavior in a real buffer, not
   a modal widget.
7. The development environment and plugin dependencies are reproducible through
   Nix flakes and direnv.
8. A small, opinionated interface is preferable to configuration and extension
   machinery.

## Primary workflow

The normal review loop is:

1. Open a source file and move to the relevant line, or visually select a line
   range.
2. Press `<leader>ra`.
3. Write a plain-text annotation in a regular Neovim buffer.
4. Save and close it with `:wq`.
5. Repeat throughout the review.
6. Optionally press `<leader>rf` to search and manage all annotations on the
   current branch in Telescope.
7. Press `<leader>rE` to export every annotation on the current branch as
   Markdown to the system clipboard.

Export does not delete or resolve annotations.

## 1. Annotation data model

Each annotation persists only what is needed for Markdown export, source
navigation, and branch isolation.

Required fields:

- Stable unique ID.
- Git branch name at creation time.
- Project-relative file path.
- One-based start and end lines.
- Plain multiline annotation text.
- Captured source snippet with numbered lines.

There is deliberately no annotation `type`, resolved state, symbol context,
commit SHA, diff/hunk information, or source fingerprint. Locally created
annotations store no GitHub fields. Imported review comments may carry an
optional `origin` object containing GitHub identity, attribution, URL, and
whether their local anchor is exact or approximate.

The JSON document has a schema version so unsupported data is detected cleanly.
Derived UI state such as Telescope selection, open buffer IDs, and extmarks must
not be serialized as authoritative data.

## 2. Branch scope

- Every annotation belongs to the branch on which it was created.
- Signs, navigation, Telescope results, and exports show only annotations for
  the current branch.
- Switching branches refreshes the visible annotations without requiring a
  Neovim restart.
- Annotations for other branches remain in JSON and reappear when their branch
  becomes current again.
- Branch names are data, not store filenames, so slashes and branch renames do
  not create unsafe paths.
- A detached `HEAD` has no named current branch and is unsupported for adding,
  browsing, or exporting annotations.
- An unborn branch may use its symbolic branch name.

A single project-level JSON store containing branch-tagged annotations is the
preferred model. It keeps branch changes and inspection simpler than one file
per branch.

## 3. Adding and editing in a normal buffer

Adding or editing opens a named annotation buffer in a regular Neovim split.
It must support normal motions, undo, registers, paste, completion, and any
ordinary user mappings that apply to its filetype.

The annotation buffer should behave as follows:

- Use a recognizable name such as `vrv://annotation/<id-or-new>`.
- Use Markdown filetype for prose editing.
- Use `buftype=acwrite` so `:write` is handled by the plugin without creating a
  stray filesystem file.
- Contain only the annotation text; its source association is buffer-local state
  rather than editable boilerplate.
- Start empty for a new annotation and prefilled for an edit.
- `:w` validates and persists the annotation while keeping the buffer open.
- `:wq` persists it and closes the annotation split.
- `:q!` cancels unsaved changes.
- Refuse to create a new annotation whose trimmed text is empty.
- Return focus to the source window after the annotation buffer closes.
- Prevent two buffers from independently editing the same annotation without a
  conflict warning.

The source location and context snippet are captured when add is invoked, before
the editor buffer opens. Editing an annotation changes only its text; it does
not silently move the annotation or replace its original context.

Add behavior:

- In normal mode, annotate the cursor line.
- In visual mode, annotate the selected line range.
- Line ranges are line-based even if the selection was characterwise or
  blockwise.
- Do not detect, expand to, or store diff hunks.

## 4. Source display and position tracking

- Show a single, clearly visible sign at each annotation's starting line.
- Use one fixed icon and highlight because annotations have no type.
- Use extmarks to follow line insertions and deletions while a buffer is open.
- Synchronize moved extmark positions into JSON before export and when safely
  persisting editor changes.
- Re-render signs when entering a file, changing projects, or changing Git
  branches.
- Do not display annotations from other branches.
- Keep multiline ranges intact by applying start-line drift to the end line.

The stored snippet remains the historical review context used for deterministic
exports. Current source may separately be used for previews, but must not mutate
the captured snippet merely because a file was opened.

There is no stale-annotation detection, source fingerprinting, cross-session
re-anchoring, or moved-code search. Extmarks improve positions only while the
relevant source buffer is open. Otherwise the stored file and line remain as-is,
and the user may edit, delete, or recreate an annotation if the source moved.

## 5. Telescope annotation browser

Telescope is the one supported annotation browser. There is no Snacks,
fzf-lua, or generic picker abstraction in the initial version.

The browser must:

- List every annotation on the current Git branch.
- Fuzzy-search annotation text, file path, and captured source text.
- Show file path, line/range, and a compact annotation preview in each result.
- Preview the current source file at the stored annotation location.
- `<CR>`: jump to the selected source location.
- `<C-d>`: immediately delete the selected annotation, persist the deletion,
  remove its sign, and refresh the Telescope results without closing the picker.
- `<C-e>`: open the selected annotation in the normal edit buffer.
- Exit normally with Telescope's standard close mappings.

Deletion inside Telescope affects only the selected annotation. Bulk picker
actions and resolved-state workflows are out of scope.

## 6. Direct management and navigation

The useful parts of the existing interaction model remain available:

- Edit the annotation under the cursor in the normal annotation buffer.
- Delete the annotation under the cursor.
- Clear every annotation on the current branch with one command, without
  affecting annotations stored for other branches.
- If multiple ranges overlap the cursor, use the Telescope browser filtered to
  those annotations to disambiguate.
- Jump to the next or previous annotation on the current branch, wrapping across
  files.
- Reload the JSON store and signs without restarting Neovim.

There is no separate read-only view popup. Viewing happens in Telescope or by
opening the annotation in its edit buffer.

## 7. JSON persistence

JSON is the only durable representation. Markdown is never read back as state.

- Use the fixed project-relative store path
  `.cache/vrv/annotations.json`.
- Detect the repository root with Git and fall back to Neovim's working
  directory only for repositories with no usable Git root.
- Create parent directories on first write.
- Load the store during setup and on explicit reload.
- Save after every successful add, edit, or delete.
- Write atomically through a sibling temporary file followed by rename so a
  crash cannot leave partially written JSON.
- Detect malformed or unsupported stores and preserve the original file rather
  than overwriting it with an empty store.
- Leave `.gitignore` untouched; users decide whether to ignore the store path.

The implementation assumes only one Neovim instance manages a repository at a
time. It does not need file locking, external-change detection, merging, or
multi-writer conflict protection.

The serializer and deserializer must be independently testable. Transformations
must accept the decoded JSON model rather than reaching into editor UI state.

## 8. Markdown export

`<leader>rE` exports all annotations for the current branch to the system
clipboard. The order is deterministic: project-relative file path, then start
line, then stable ID.

The layout retains the useful parts of the previous exporter but removes type
labels:

````markdown
## @path/to/file.lua

### path/to/file.lua — line 42

```lua
39: context above
40: context above
41: context above
42: annotated source line
43: context below
44: context below
45: context below
```

The annotation text.
````

Export requirements:

- Preserve numbered source context above and below the annotated range.
- Use the stored historical snippet, making the transformation deterministic
  even if the working tree later changes.
- Include a Markdown fence language derived from the stored file path.
- Include line or range information.
- Do not include a document title, date, introduction, preamble, summary, file
  count, annotation count, or file list.
- Begin directly with the first `## @path/to/file` section.
- Notify after copying successfully.
- Do not clear annotations after export.
- Report an empty current-branch review without modifying the clipboard.

The Markdown formatter should be a pure function from the branch-filtered JSON
model to a string and should have snapshot tests.

## 9. GitHub CLI review integration

The GitHub transformation:

- Read the same JSON annotations as Markdown export.
- Select annotations for the current branch/pull request.
- Convert ordinary, non-deleted source lines into GitHub pull-request review
  comment coordinates using the repository and pull request state available at
  export time.
- Produce a machine-readable payload that can be piped to `gh api` or consumed
  by a small `gh` wrapper to create one pull-request review.
- Preserve multiline comments and multiline source ranges where GitHub supports
  them.
- Clearly reject or report annotations that cannot be mapped to an ordinary line
  in the pull-request diff rather than posting them at a guessed location.
- Copy a pending-review JSON body that can be passed directly to `gh api`.
- Import every inline review comment and reply from a selected pull request.
- Persist optional GitHub provenance for idempotence and to distinguish exact
  from approximate anchors.

Local annotations cannot target deleted lines. When importing a left-side
deletion comment, use the nearest following surviving line in the comment hunk,
then the nearest preceding line. Skip and report comments whose file was
entirely deleted or whose surviving context cannot be re-anchored
unambiguously.

## 10. Commands and keybindings

The initial fixed mappings are:

| Mapping | Modes | Behavior |
| --- | --- | --- |
| `<leader>ra` | Normal, visual | Add annotation |
| `<leader>rd` | Normal | Delete annotation under cursor |
| `<leader>re` | Normal | Edit annotation under cursor |
| `<leader>rf` | Normal | Open current-branch Telescope browser |
| `<leader>rC` | Normal | Clear all annotations on the current branch |
| `<leader>rE` | Normal | Export current branch as Markdown to clipboard |
| `]r` | Normal | Jump to next current-branch annotation |
| `[r` | Normal | Jump to previous current-branch annotation |

Equivalent commands should exist for scripting and discoverability:

- `:Vrv add`
- `:Vrv delete`
- `:Vrv edit`
- `:Vrv browse`
- `:Vrv clear`
- `:Vrv export`
- `:Vrv export markdown`
- `:Vrv export github [PR]`
- `:Vrv import github [PR]`
- `:Vrv next`
- `:Vrv prev`
- `:Vrv reload`

The plugin name is `vrv` and the command prefix is `:Vrv`. There is no broad
configuration system in the first version; the mappings and behavior are
intentionally opinionated.

## 11. Nix flake and development environment

The repository must include:

- `flake.nix` and a committed `flake.lock` to pin nixpkgs and all flake inputs.
- `.envrc` containing `use flake` so direnv enters the development shell after
  the repository has been allowed once.
- A default development shell with pinned Neovim, Git, Lua tooling, formatter,
  linter, and test dependencies.
- A reproducible headless Neovim test environment containing the plugin and its
  runtime dependencies, including Telescope.
- Flake checks for tests and formatting/linting where practical.
- A buildable Neovim plugin package exposed as
  `packages.<system>.default` and a stable named package.
- `overlays.default` so another flake can add the plugin to its package set.
- Dependency declarations that let downstream flakes install the plugin with
  the required Neovim plugins rather than manually recreating the test setup.

The target result is usable both as a standalone development checkout and as an
input to a larger personal Neovim flake.

## 12. Explicitly out of scope

The initial rewrite does not include:

- Annotation types, type cycling, type icons, or type-specific highlights.
- nui.nvim or any add/edit/view modal.
- Snacks or fzf-lua picker adapters.
- User-defined annotation types.
- A general configuration schema.
- Custom exporter or formatter registries.
- Avante or CodeCompanion exporters.
- Resolved/unresolved annotation state.
- Resolve-all, export-and-clear, or export-current-file workflows.
- File-prompt export or configurable export filenames.
- Statusline integration.
- Stale validation, source fingerprints, or automatic re-anchoring.
- Commit, diff-side, hunk, or symbol metadata.
- Concurrent/multiple-Neovim-instance protection for the same repository.
- Migration or importing from meow.review; existing annotation data may be
  deleted.
- Extensive end-user documentation or support for multiple plugin managers.
- The GitHub CLI transformation itself.

## 13. Confirmed product choices

These choices are fixed for the initial implementation.

| Choice | Requirement |
| --- | --- |
| Annotation editor placement | Full-width horizontal split; `:wq` saves and closes only that split |
| Context size | Keep three lines above and below the selected range |
| Telescope deletion confirmation | No prompt; `<C-d>` is immediate and refreshes the picker |
| Markdown destination | System clipboard through the `+` register |
| Store path | `.cache/vrv/annotations.json`; `.gitignore` remains user-managed |
| Unsaved source buffers | Capture the live buffer text and line positions, then persist that snapshot in JSON |
| Plugin/command name | Use `vrv` / `:Vrv` |
