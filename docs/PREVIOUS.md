# Previous Functionality

## Purpose

This document inventories the previous user-facing behavior of
[`retran/meow.review.nvim`](https://github.com/retran/meow.review.nvim) as the
baseline for our rewrite. It is a capability inventory, not yet the final product
specification: each item can later be kept, changed, or deliberately removed.

Reference inspected: `main` at commit
[`904880b`](https://github.com/retran/meow.review.nvim/commit/904880b83448adc7e9ba4c913a19adf21d4dc8e4)
(2026-05-01), including its README, Vim help, Lua implementation, tests, and
changelog.

## Product model

The plugin lets a user attach a typed, multiline review comment to a line, a
line range, or a diff hunk. An annotation belongs to a project-relative file and
stores enough source context to remain useful outside Neovim. Annotations are
persisted per project, displayed in the editor, navigated and managed in Neovim,
and exported in a format intended for either a human or an AI coding agent.

An annotation contains the following durable information:

- A unique ID and creation/update timestamp.
- A project-relative file path.
- A one-based start and end line.
- An annotation type.
- Multiline comment text.
- An optional Treesitter symbol name.
- An optional source snippet and its starting line.
- Optional diff-hunk header, start, and end positions.
- A resolved/unresolved state.

Runtime-only state tracks the annotation's extmark, buffer, and whether it looks
stale.

## 1. Creating annotations

- Add an annotation from normal mode at the cursor.
- Add an annotation for a linewise visual selection.
- When adding in normal mode inside a detected diff hunk, annotate the whole
  added/changed range rather than only the cursor line.
- Prefer hunk information from `gitsigns.nvim`; when unavailable, detect hunks
  from two or more windows in Neovim diff mode using `vim.diff`.
- Ignore pure-deletion hunks because they have no range in the current buffer.
- Capture the innermost recognizable Treesitter function, method, class, type,
  or Markdown-heading name at the cursor when available.
- Capture a configurable number of source lines above and below the annotated
  range. Stored snippet lines have one-based line-number prefixes.
- Permit snippet capture to be disabled with `context_lines = 0`.
- Open a centered, multiline Markdown editing popup for the comment.
- Show the selected line/range or hunk and optional symbol in the popup border.
- Show the current annotation type in the popup border.
- Trim surrounding whitespace on save and do not create an annotation from an
  empty comment.
- Save immediately after creation and place the annotation marker in the
  current buffer.

Range precedence in the reference implementation is:

1. An explicit visual range.
2. A detected hunk.
3. The cursor line.

## 2. Annotation types

The built-in semantic types are:

| Type | Meaning | Default highlight |
| --- | --- | --- |
| `ISSUE` | A blocking problem to fix | `DiagnosticError` |
| `SUGGESTION` | A non-blocking improvement | `DiagnosticWarn` |
| `NOTE` | An informational observation or question | `DiagnosticInfo` |

Type behavior is configurable:

- Replace the complete built-in type set with a user-defined type table.
- Configure each type's sign icon, highlight group, display label, and legacy
  sign name.
- Configure the order in which the modal cycles through types.
- If custom types are provided without an explicit order, cycle through their
  keys alphabetically.
- If no custom types are provided, cycle `ISSUE` → `SUGGESTION` → `NOTE`.

## 3. Add/edit modal behavior

The add and edit actions use the same multiline modal. Edit starts with the
existing text and type and places the cursor at the end.

| Key | Mode | Behavior |
| --- | --- | --- |
| Configurable, default `<C-t>` | Insert | Cycle annotation type |
| `<C-s>` | Insert or normal | Save |
| `<CR>` | Normal | Save |
| `<Esc>` | Insert | Leave insert mode |
| `<Esc>` or `q` | Normal | Cancel |
| `<C-c>` | Insert | Cancel |

The modal closes without saving when it loses its buffer/window focus. Its width
and height are configurable.

## 4. Displaying annotations

- Display one sign-column marker at each annotation's starting line.
- Use the annotation type's icon and highlight.
- Force the sign column on in windows showing a buffer with a marker when it was
  previously disabled.
- Render annotations already present in open buffers during setup.
- Render a file's annotations when its buffer is entered.
- Use extmarks so a marker moves as lines are inserted or deleted.
- Before position-sensitive operations, copy extmark drift back into the stored
  start line and move the end line by the same offset.
- Use a neutral `MeowReviewResolved` highlight for resolved annotations.
- Use a warning-like `MeowReviewStale` highlight for stale annotations.
- Allow users to override the relevant Neovim highlight groups.

## 5. Viewing, editing, and deleting

- View the annotation under the cursor in a floating popup.
- The view popup shows type, file, range or hunk, optional symbol, multiline
  comment, timestamp, and resolved/stale badges.
- Close the view popup with `q`, `<Esc>`, or by leaving it.
- Edit the annotation under the cursor, including both its type and text.
- Deleting removes the annotation and its marker and persists the change.
- Treat every line covered by an annotation's range or hunk as being “under”
  that annotation, not just its starting line.
- If multiple annotations overlap the cursor, use the annotation picker to
  choose which one to view, edit, or delete.
- Warn rather than failing when the cursor has no applicable annotation.

Editing updates the annotation timestamp. It does not recapture the source
snippet, symbol, file, range, or hunk metadata.

## 6. Resolving and clearing

- Resolve the first annotation found under the cursor.
- Resolve all annotations after confirmation.
- Persist resolved state.
- Exclude resolved annotations from normal sorted queries, navigation, pickers,
  and exports.
- Keep resolved annotations in the store so they can still be found directly at
  their location and included by lower-level callers that explicitly request
  them.
- Clear every annotation after confirmation, remove all markers from loaded
  buffers, and persist the empty store.
- Do nothing destructive if a confirmation prompt is cancelled or dismissed.

There is no user-facing “unresolve” action in the reference plugin.

## 7. Navigation and pickers

- Open a picker containing every unresolved annotation.
- Open the same picker filtered to the current file.
- Filter by annotation type, either from a supplied type name or by first asking
  the user to select a type that currently has annotations.
- Show each picker entry's status badge, type, file, line/range or hunk, symbol,
  and comment text.
- Jump to the selected annotation, opening its file when needed and positioning
  the cursor at its starting line.
- Warn and remain stable when an annotation's file no longer exists.
- Jump to the next or previous unresolved annotation sorted by file and line.
- Wrap at the beginning/end of the annotation list.
- Cross file boundaries and skip unreadable annotation files.

Picker backend preference is:

1. `snacks.nvim`, with file preview.
2. `telescope.nvim`, with fuzzy sorting and preview.
3. `fzf-lua`.
4. `nui.menu` as the required-dependency fallback.

## 8. Persistence and project scope

- Detect the project root with `git rev-parse --show-toplevel` from the current
  buffer's directory.
- Fall back to Neovim's current working directory outside a Git repository.
- Keep one JSON store per detected project by default at
  `.cache/meow-review/annotations.json`.
- Allow a project-relative or absolute store path.
- Create missing parent directories on first write.
- Store a schema version and reject unreadable JSON or unsupported versions with
  a warning.
- Load annotations during setup.
- Reload them manually from disk and re-render markers.
- Reload the appropriate store when Neovim's working directory changes, enabling
  multi-project sessions driven by `:cd`, `:lcd`, or equivalent directory
  changes.
- Save on add, edit, delete, resolve, resolve-all, and clear.
- Persist extmark-adjusted positions on the next save.

The store can be managed in `.gitignore`:

- `auto_gitignore = "prompt"` asks whether to append the store path after a
  successful save when it is not already ignored.
- `auto_gitignore = "always"` appends it automatically.
- `auto_gitignore = false` leaves `.gitignore` untouched.
- Relative store paths are anchored at the project root in the generated ignore
  rule.

## 9. Stale annotation detection

- Validate all stored annotations against files on disk.
- Mark an annotation stale when its file is missing.
- Mark it stale when its starting line is beyond the current file length.
- When a snippet exists, compare its first captured source line with the current
  line at the snippet's original start, ignoring leading/trailing whitespace.
- Report either that all annotations are current or list every stale annotation
  and its reason.
- Apply the stale highlight to visible markers.
- Also perform a lightweight snippet comparison while rendering signs in an
  open buffer.

This is heuristic validation. It does not search for moved code, compare the
whole snippet, or automatically re-anchor stale annotations.

## 10. Exporting reviews

Export uses unresolved annotations sorted by file and then start line.

User workflows:

- Export all annotations through the configured default exporter.
- Select a named exporter.
- Export only annotations belonging to the current file.
- Export all and clear the store only when export dispatch succeeds.
- Leave the store untouched if the exporter/formatter is unavailable, there are
  no exportable annotations, or the exporter raises an error.
- Tab-complete registered exporter names in the command line.

Built-in exporters:

| Name | Behavior |
| --- | --- |
| `clipboard` | Copy output to Neovim's `+` register; this is the default |
| `file` | Overwrite the configured export file under the project root |
| `file_prompt` | Ask for a filename, prefilled with the configured default, then write it |
| `avante` | When `avante.nvim` is installed, pass output to `avante.api.ask()` |
| `codecompanion` | When `codecompanion.nvim` is installed, pass output to `codecompanion.chat()` |

Each built-in exporter can be disabled by name. Export output directories are
created when needed. Relative output paths are resolved from the project root;
absolute paths remain absolute.

### Markdown formatter

The default Markdown document contains:

- A `# Code Review — YYYY-MM-DD` heading.
- A configurable AI-oriented instruction preamble, omitted when configured as
  an empty string.
- An optional `## Summary` with file count, annotation count, per-type counts,
  and an alphabetical file list.
- A `## @relative/path` section for each file.
- A machine-readable `### [TYPE] file — line/range/hunk — symbol` heading for
  each annotation.
- An optional fenced source snippet with stored line numbers and a language
  inferred from the file extension.
- The review comment text.

### JSON formatter

The built-in JSON formatter emits an object containing `exported_at` and an
`annotations` array.

### Extension points

- Register, replace, and unregister named exporters at runtime.
- A custom exporter receives the formatted content and absolute project root.
- Register, replace, and unregister named formatters at runtime.
- A custom formatter receives the sorted unresolved annotation list and returns
  a string.
- Configure the default exporter and default formatter.

## 11. Statusline integration

`require("meow.review").status()` returns:

- An empty string when the store has no annotations.
- A compact total count when annotations exist.
- A per-type breakdown when more than one unresolved annotation type is present,
  for example `  5 (3 ISSUE, 2 NOTE)`.

It is intended to be embedded in statusline plugins such as lualine or heirline.

## 12. User command surface

All Ex commands are subcommands of `:MeowReview`:

| Command | Behavior |
| --- | --- |
| `:MeowReview add` | Add at the cursor or a preceding visual selection |
| `:MeowReview delete` | Delete at cursor |
| `:MeowReview edit` | Edit at cursor |
| `:MeowReview view` | View at cursor |
| `:MeowReview export [exporter]` | Export all unresolved annotations |
| `:MeowReview export_and_clear [exporter]` | Export, then clear on successful dispatch |
| `:MeowReview export_file [exporter]` | Export unresolved annotations for the current file |
| `:MeowReview clear` | Confirm and clear all annotations |
| `:MeowReview goto` | Pick from all unresolved annotations |
| `:MeowReview goto_file` | Pick from unresolved annotations in the current file |
| `:MeowReview goto_type [type]` | Pick by annotation type |
| `:MeowReview resolve` | Resolve at cursor |
| `:MeowReview resolve_all` | Confirm and resolve all |
| `:MeowReview validate` | Check annotations for staleness |
| `:MeowReview reload` | Reload the JSON store and markers |
| `:MeowReview next` | Jump forward, wrapping across files |
| `:MeowReview prev` | Jump backward, wrapping across files |

Subcommand names and applicable exporter names support command-line completion.
Unknown or missing subcommands produce a usage/error notification.

## 13. Mapping surface

The plugin defines no default user keybindings. Instead, it exposes these
`<Plug>` mappings for users or plugin managers to bind:

| Mapping | Modes | Behavior |
| --- | --- | --- |
| `<Plug>(MeowReviewAdd)` | Normal, visual | Add annotation |
| `<Plug>(MeowReviewDelete)` | Normal, visual | Delete annotation at cursor |
| `<Plug>(MeowReviewEdit)` | Normal | Edit at cursor |
| `<Plug>(MeowReviewView)` | Normal | View at cursor |
| `<Plug>(MeowReviewExport)` | Normal | Export with defaults |
| `<Plug>(MeowReviewExportAndClear)` | Normal | Export with defaults and clear |
| `<Plug>(MeowReviewExportFile)` | Normal | Export current file with defaults |
| `<Plug>(MeowReviewClear)` | Normal | Clear all |
| `<Plug>(MeowReviewGoto)` | Normal | Pick any annotation |
| `<Plug>(MeowReviewGotoFile)` | Normal | Pick in current file |
| `<Plug>(MeowReviewGotoType)` | Normal | Select a type, then pick |
| `<Plug>(MeowReviewResolve)` | Normal | Resolve at cursor |
| `<Plug>(MeowReviewResolveAll)` | Normal | Resolve all |
| `<Plug>(MeowReviewReload)` | Normal | Reload store |
| `<Plug>(MeowReviewValidate)` | Normal | Validate annotations |
| `<Plug>(MeowReviewNext)` | Normal | Jump next |
| `<Plug>(MeowReviewPrev)` | Normal | Jump previous |

## 14. Configuration surface

Configuration is supplied to `require("meow.review").setup({...})` or through
`vim.g.meow_review` before setup. Setup is intended to be safe to call more than
once.

| Option | Reference default | User-facing effect |
| --- | --- | --- |
| `context_lines` | `3` | Source lines captured above/below the target |
| `disabled_exporters` | `{}` | Built-in/integration exporters not registered |
| `default_exporter` | `"clipboard"` | Exporter used when none is named |
| `default_formatter` | `"markdown"` | Formatter used for exports |
| `export_filename` | `".review.md"` | Default file export target |
| `store_path` | `".cache/meow-review/annotations.json"` | Persistent JSON store |
| `modal_width` | `64` | Add/edit popup width |
| `modal_height` | `6` | Add/edit popup height |
| `modal_cycle_key` | `"<C-t>"` | Insert-mode type-cycle key |
| `auto_gitignore` | `"prompt"` | Whether/how to ignore the store |
| `prompt_preamble` | AI-fix instruction text | Markdown preamble |
| `export_summary` | `true` | Include Markdown summary |
| `annotation_types` | built-in set | Complete active type definitions |
| `annotation_type_order` | built-in order or sorted custom keys | Modal cycling order |

Invalid configuration emits an error and causes the internal configuration
reader to fall back to all defaults.

## 15. Public Lua API

The module returned by `require("meow.review")` exposes:

- Lifecycle: `setup(opts)`.
- Annotation actions: `add_comment(is_visual)`, `edit_comment()`,
  `delete_comment()`, `view_comment()`.
- Resolution/validation: `resolve_comment()`, `resolve_all_comments()`,
  `validate()`.
- Navigation: `goto_comment()`, `goto_comment_in_file()`,
  `goto_comment_by_type(type_name)`, `next_comment()`, `prev_comment()`.
- Store workflows: `clear_all()`, `reload()`.
- Export workflows: `export_review(name)`, `export_and_clear(name)`,
  `export_current_file(name)`.
- Extensibility: `register_exporter(name, fn)`, `unregister_exporter(name)`,
  `register_formatter(name, fn)`, `unregister_formatter(name)`.
- UI integration: `status()`.

## 16. Dependencies and diagnostics

- Require Neovim 0.11 or later; refuse to load on older versions.
- Require `nui.nvim` for modals and fallback menus, but defer the dependency
  error until a relevant action is used.
- Treat Treesitter, gitsigns, Snacks, Telescope, fzf-lua, Avante, and
  CodeCompanion as optional enhancements.
- Provide `:checkhealth meow.review`.
- Report Neovim compatibility; nui.nvim, Treesitter, gitsigns, and Snacks
  availability; configuration validity and selected values; registered/disabled
  exporters; detected project root; annotation count; store-file presence; and
  basic troubleshooting information.
- Notify users about successful mutations/exports, empty result sets,
  cancellations, missing files, configuration errors, store parse/version
  errors, and exporter failures.

## Reference inconsistencies to decide during the rewrite

These are contradictions or externally visible quirks in the inspected version.
They should be consciously resolved in the final specification rather than
copied accidentally.

1. **Built-in icons:** README/help advertise distinct built-in icons, but the
   checked-in type definitions use empty strings for all three icons. The rewrite
   needs an explicit default icon policy.
2. **Default export filename:** the implementation and README use `.review.md`;
   parts of the Vim help claim `.cache/meow-review/review.md`.
3. **Formatter selection syntax:** Vim help shows
   `:MeowReview export clipboard xml`, but the command implementation ignores the
   second argument. In practice, users choose a formatter through
   `default_formatter` (or lower-level internals), not per export command.
4. **Type labels in Markdown:** types define a configurable `label`, but Markdown
   headings use the annotation's raw type key. The label currently affects modal
   display, not export headings.
5. **Resolved marker refresh:** resolved annotations have a dedicated highlight,
   but resolving does not immediately re-render the extmark in the inspected
   implementation.
6. **Status count semantics:** the total uses all stored annotations while the
   type breakdown is computed from unresolved annotations. A mixed
   resolved/unresolved store can therefore produce inconsistent-looking output.
7. **Stale state:** validation highlights stale visible signs and reports
   results, but does not durably store staleness or re-anchor moved code. Open
   buffer rendering and explicit validation also differ slightly for hunk-based
   annotations.
8. **Prompt frequency:** documentation describes the `.gitignore` prompt as
   “ask once,” but dismissing it leaves no remembered choice, so later saves may
   prompt again.
9. **Project switching:** automatic store switching is tied to `DirChanged`, not
   simply opening a buffer from another repository.
10. **Export success:** asynchronous or side-effecting exporters are considered
    successful when their function returns without throwing. File exporters do
    not return their internal write result, and `file_prompt` returns before the
    user answers; this makes `export_and_clear` capable of clearing before a
    prompted export is completed or after a non-throwing write failure.
