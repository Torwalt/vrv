# vrv.nvim

An opinionated, branch-scoped code review annotation plugin for Neovim. The
implemented behavior is specified in [`docs/FEATURES.md`](docs/FEATURES.md).

## Nix flake installation

Add this repository as an input, apply its overlay, and include `vrv-nvim` in
your Neovim plugins. Telescope and Plenary are propagated by the package.

```nix
{
  inputs.vrv.url = "path:/path/to/vrv";

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

The plugin initializes when Neovim loads it. Git must be available at runtime.
For development, run `direnv allow` once or enter `nix develop`, then run
`vrv-nvim .`. The launcher prefers the Neovim wrapper in your user profile so
your normal configuration and plugins load, while prepending this checkout to
the runtime path. Set `VRV_USER_NVIM=/path/to/nvim` to select another wrapper.
If no user wrapper is found, it falls back to the pinned development Neovim.
