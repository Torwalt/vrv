# vrv.nvim

`vrv.nvim` is a small, opinionated Neovim plugin for writing code-review
annotations while reading a repository locally.

Move to a line, press `<leader>ra`, write the comment in a normal Neovim buffer,
and close it with `:wq`. Annotations are stored as branch-scoped JSON. When the
review is ready, `<leader>rE` copies a compact Markdown review—with file paths,
line numbers, and source context—to the system clipboard.

There are no local annotation types, modal forms, or configuration framework.
Imported GitHub annotations retain their thread state, but the plugin remains
intentionally built around one workflow.

## What it does

- Adds plain-text annotations to a line or visual line range.
- Opens annotations in a full-width Markdown buffer with ordinary Neovim
  editing, undo, registers, completion, `:w`, `:wq`, and `:q!`.
- Captures three numbered context lines above and below the selected range,
  including unsaved source-buffer changes.
- Stores annotations for every branch in
  `.cache/vrv/annotations.json`.
- Shows annotation signs in source buffers and follows in-session line movement
  with extmarks.
- Searches the current branch's annotations through Telescope.
- Navigates between annotations across files.
- Exports deterministic Markdown to the `+` clipboard register.
- Exports a pending-review JSON payload ready for `gh api`.
- Imports unresolved GitHub review threads by default, including best-effort
  anchors for deleted lines, with optional resolved threads and replies.
- Clears all annotations on the current branch without affecting other branches.

## Requirements

- Neovim 0.11.7 or newer.
- Git.
- [GitHub CLI](https://cli.github.com/) for GitHub import and export.
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim).
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).
- A working Neovim clipboard provider for Markdown export. Check it with
  `:checkhealth provider`.

The Nix package supplies Git, GitHub CLI, Telescope, and Plenary.

## Installation

### Nix flake

Use the local checkout while developing:

```nix
{
  inputs.vrv.url = "path:/home/ada/repos/vrv";
  inputs.vrv.inputs.nixpkgs.follows = "nixpkgs";
}
```

Once the repository is hosted, replace the path with its Git flake URL, for
example `github:OWNER/vrv`.

Apply the overlay and install `vrv-nvim` as a Neovim plugin:

```nix
{
  outputs = { nixpkgs, vrv, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ vrv.overlays.default ];
      };
    in {
      packages.${system}.neovim = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
        plugins = [ pkgs.vrv-nvim ];
      };
    };
}
```

For a Home Manager configuration using the same `pkgs` instance, the relevant
part is simply:

```nix
programs.neovim.plugins = [ pkgs.vrv-nvim ];
```

The package declares Telescope and Plenary as plugin dependencies, so they are
included by Nix's Neovim wrapper.

### lazy.nvim

Until the repository has a public remote, point lazy.nvim at the checkout:

```lua
{
  dir = "/home/ada/repos/vrv",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
}
```

For a hosted repository, replace `dir` with the repository's normal lazy.nvim
source declaration.

The plugin initializes automatically from `plugin/vrv.lua`; no `setup()` call is
required.

## Workflow

1. Open a file inside a Git repository.
2. Put the cursor on a line, or visually select a range.
3. Press `<leader>ra`.
4. Write the review comment in the annotation split.
5. Use `:wq` to save it and return to the source file.
6. Repeat as needed.
7. Use `<leader>rf` to search, jump to, edit, or delete annotations.
8. Press `<leader>rE` to copy the current branch's Markdown review.
9. Optionally use `:Vrv export github` to create GitHub review JSON.
10. Use `:Vrv import github` to bring unresolved GitHub review threads into the
    same browser.

Annotations are isolated by symbolic Git branch. Switching branches updates the
visible signs and changes what appears in Telescope and exports. Detached HEAD
is intentionally unsupported.

## Mappings and commands

The mappings are fixed in the current version.

| Mapping | Modes | Command | Action |
| --- | --- | --- | --- |
| `<leader>ra` | Normal, visual | `:Vrv add` | Add an annotation at the cursor or selected line range |
| `<leader>rd` | Normal | `:Vrv delete` | Delete the annotation under the cursor |
| `<leader>re` | Normal | `:Vrv edit` | Edit the annotation under the cursor |
| `<leader>rf` | Normal | `:Vrv browse` | Browse current-branch annotations in Telescope |
| `<leader>rC` | Normal | `:Vrv clear` | Immediately clear all annotations on the current branch |
| `<leader>rE` | Normal | `:Vrv export` | Copy current-branch Markdown to the system clipboard |
| `]r` | Normal | `:Vrv next` | Jump to the next annotation, wrapping across files |
| `[r` | Normal | `:Vrv prev` | Jump to the previous annotation, wrapping across files |

`:Vrv reload` reloads JSON from disk and redraws signs.

`:Vrv export markdown` is the explicit form of `:Vrv export`. Use
`:Vrv export github [PR]` to copy a GitHub review payload. GitHub import is
thread-oriented:

- `:Vrv import github [PR]` imports unresolved root comments.
- Add `--replies` to import each reply as a separate annotation.
- Add `--all` to include resolved threads. The flags can be combined.
- `:Vrv resolve github` resolves an imported thread under the cursor on GitHub
  and marks every local annotation from that thread resolved.

`PR` may be a pull-request number or URL; when omitted, GitHub CLI resolves the
pull request for the current branch. Resolving is an explicit GitHub write;
import and export do not change the pull request.

The Telescope browser adds these actions:

| Mapping | Action |
| --- | --- |
| `<CR>` | Jump to the selected source location |
| `<C-e>` | Edit the selected annotation |
| `<C-d>` | Immediately delete the selected annotation and refresh the picker |

When several annotation ranges overlap the cursor, edit and delete open a
filtered Telescope picker for disambiguation.

## Annotation editor

The editor is a regular Markdown `acwrite` buffer named
`vrv://annotation/<id-or-new>`. It contains only the annotation text.

- `:w` validates and persists the text while leaving the split open.
- `:wq` persists it and closes only the annotation split.
- `:q!` discards unsaved changes.
- Empty or whitespace-only annotations cannot be saved.

Editing an existing annotation changes only its text. Its originally captured
source context remains unchanged so later exports are deterministic.

## Persistence

JSON is the source of truth:

```text
<repository>/.cache/vrv/annotations.json
```

The file contains annotations for all branches and is rewritten atomically after
successful changes. Markdown and GitHub exports are transformations of this
JSON and are never read back as state. Stores written by the current version use
schema version 2; version 1 stores are read and migrated on their next save.

`vrv.nvim` does not modify `.gitignore`. Add the store path there yourself if
you do not want Git to track it.

Malformed or unsupported JSON is preserved and the store becomes read-only.
Fix the file and run `:Vrv reload` rather than losing annotations to an automatic
reset.

The implementation assumes one Neovim instance manages a repository at a time.

## Markdown export

The export starts directly with a file section and contains no title, preamble,
summary, type labels, or counts:

````markdown
## @lua/example.lua

### lua/example.lua — line 42

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

Files, lines, and annotations have deterministic ordering. Exporting an empty
branch reports that there are no annotations and leaves the clipboard unchanged.

## GitHub review integration

GitHub export requires local `HEAD` to match the pull request's head commit. It
maps annotations only to right-side lines in one pull-request diff hunk and
refuses the complete export if any annotation is not commentable. The copied
JSON omits `event`, so posting it creates a pending review:

```sh
gh api -X POST repos/OWNER/REPO/pulls/NUMBER/reviews --input review.json
```

Import fetches review threads through GitHub's GraphQL API. It imports only
unresolved root comments by default; unresolved outdated threads are retained.
`--all` also includes resolved threads, while `--replies` imports replies as
separate annotations. Current right-side comments retain their exact line or
range. File comments use line 1. Deleted left-side comments use the nearest
following surviving line in their hunk, then the nearest preceding line;
ambiguous anchors and entirely deleted files are reported and skipped.
Repeating an import does not duplicate comments.

Imported annotations use a `G` sign. Telescope prefixes them with `[GH]` for an
exact open thread, `[GH~]` for an outdated or approximately anchored thread,
and `[GH✓]` for a resolved thread. Root comments show the author and reply
count; separately imported replies are marked `reply`.

## Developing and testing locally

The repository includes a pinned development shell and `.envrc`:

```sh
direnv allow
vrv-nvim .
```

`vrv-nvim` launches the Neovim wrapper from your user profile, loads your normal
configuration, and prepends the current checkout to `runtimepath`. Override the
wrapper when necessary:

```sh
VRV_USER_NVIM=/path/to/nvim vrv-nvim .
```

Without direnv:

```sh
nix develop -c vrv-nvim .
```

Confirm which implementation Neovim loaded:

```vim
:lua print(vim.api.nvim_get_runtime_file("lua/vrv/init.lua", false)[1])
```

Run every build, test, formatting, lint, package, and downstream-consumer check:

```sh
nix flake check -L
```

Other useful commands:

```sh
nix build .#vrv-nvim
nix run .#nvim -- .
nix fmt
```

`nix run .#nvim` uses the reproducible packaged Neovim rather than your personal
configuration.
