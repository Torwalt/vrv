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
For development, run `direnv allow` once or enter `nix develop`; `vrv-nvim`
launches Neovim with the checkout and its dependencies on the runtime path.
