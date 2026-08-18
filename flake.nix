{
  description = "vrv - branch-scoped code review annotations for Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkVrvPlugin =
        pkgs:
        pkgs.vimUtils.buildVimPlugin {
          pname = "vrv.nvim";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./lua
              ./plugin
            ];
          };
          dependencies = with pkgs.vimPlugins; [
            telescope-nvim
            plenary-nvim
          ];
          runtimeDeps = [
            pkgs.gh
            pkgs.git
          ];
          meta = {
            description = "Branch-scoped code review annotations for Neovim";
            platforms = pkgs.lib.platforms.all;
          };
        };

      overlay = final: _prev: {
        vrv-nvim = mkVrvPlugin final;
      };

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };

      mkDevNeovim =
        pkgs:
        pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
          plugins = with pkgs.vimPlugins; [
            telescope-nvim
            plenary-nvim
          ];
        };

      mkPackagedNeovim =
        pkgs:
        pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
          plugins = [ pkgs.vrv-nvim ];
        };

      mkDevLauncher =
        pkgs: devNeovim:
        pkgs.writeShellApplication {
          name = "vrv-nvim";
          runtimeInputs = [
            devNeovim
            pkgs.gh
            pkgs.git
          ];
          text = ''
            if vrv_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
              export VRV_DEV_ROOT="$vrv_root"
            else
              export VRV_DEV_ROOT="$PWD"
            fi

            vrv_user_nvim="''${VRV_USER_NVIM:-}"
            if [ -z "$vrv_user_nvim" ]; then
              for vrv_candidate in \
                "$HOME/.nix-profile/bin/nvim" \
                "/etc/profiles/per-user/''${USER:-}/bin/nvim" \
                "/run/current-system/sw/bin/nvim"
              do
                if [ -x "$vrv_candidate" ] && [ "$(readlink -f "$vrv_candidate")" != "$(readlink -f "${devNeovim}/bin/nvim")" ]; then
                  vrv_user_nvim="$vrv_candidate"
                  break
                fi
              done
            fi

            if [ -z "$vrv_user_nvim" ]; then
              vrv_user_nvim="${devNeovim}/bin/nvim"
            elif [ ! -x "$vrv_user_nvim" ]; then
              echo "vrv-nvim: VRV_USER_NVIM is not executable: $vrv_user_nvim" >&2
              exit 1
            fi

            exec "$vrv_user_nvim" --cmd 'lua vim.opt.runtimepath:prepend(vim.env.VRV_DEV_ROOT)' "$@"
          '';
        };

      mkWritableHome = ''
        export HOME="$TMPDIR/home"
        export XDG_CONFIG_HOME="$TMPDIR/config"
        export XDG_DATA_HOME="$TMPDIR/data"
        export XDG_STATE_HOME="$TMPDIR/state"
        export XDG_CACHE_HOME="$TMPDIR/cache"
        mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
      '';
    in
    {
      overlays.default = overlay;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.vrv-nvim;
          inherit (pkgs) vrv-nvim;
          nvim-with-vrv = mkPackagedNeovim pkgs;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          nvim = {
            type = "app";
            program = "${mkPackagedNeovim pkgs}/bin/nvim";
            meta.description = "Launch Neovim with vrv and its runtime dependencies";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          devNeovim = mkDevNeovim pkgs;
          devLauncher = mkDevLauncher pkgs devNeovim;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              devNeovim
              devLauncher
              pkgs.gh
              pkgs.git
              pkgs.ripgrep
              pkgs.stylua
              pkgs.nixfmt
              pkgs.lua-language-server
              pkgs.lua51Packages.luacheck
              pkgs.statix
              pkgs.deadnix
              pkgs.direnv
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          devNeovim = mkDevNeovim pkgs;
          packagedNeovim = mkPackagedNeovim pkgs;
          consumerPkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
          consumerNeovim = consumerPkgs.wrapNeovimUnstable consumerPkgs.neovim-unwrapped {
            plugins = [ consumerPkgs.vrv-nvim ];
          };
        in
        {
          package = pkgs.vrv-nvim;

          smoke = pkgs.runCommand "vrv-smoke" { nativeBuildInputs = [ packagedNeovim ]; } ''
            ${mkWritableHome}
            nvim --headless -e -u NORC -i NONE \
              -c 'lua assert(vim.g.loaded_vrv == 1); assert(require("vrv").setup() == require("vrv")); assert(require("telescope")); assert(require("plenary"))' \
              -c 'qa!'
            touch "$out"
          '';

          tests =
            pkgs.runCommand "vrv-tests"
              {
                nativeBuildInputs = [
                  devNeovim
                  pkgs.git
                ];
              }
              ''
                ${mkWritableHome}
                nvim --headless -u ${self}/tests/minimal_init.lua -i NONE -l ${self}/tests/smoke.lua
                nvim --headless -u ${self}/tests/minimal_init.lua -i NONE -l ${self}/tests/run.lua
                touch "$out"
              '';

          format =
            pkgs.runCommand "vrv-format"
              {
                nativeBuildInputs = [
                  pkgs.stylua
                  pkgs.nixfmt
                  pkgs.lua51Packages.luacheck
                  pkgs.statix
                  pkgs.deadnix
                ];
              }
              ''
                stylua --config-path ${self}/.stylua.toml --check ${self}/lua ${self}/plugin ${self}/tests
                luacheck --config ${self}/.luacheckrc ${self}/lua ${self}/plugin ${self}/tests
                nixfmt --check ${self}/flake.nix
                statix check ${self}/flake.nix
                deadnix --fail ${self}/flake.nix
                touch "$out"
              '';

          downstream = pkgs.runCommand "vrv-downstream" { nativeBuildInputs = [ consumerNeovim ]; } ''
            ${mkWritableHome}
            nvim --headless -e -u NORC -i NONE \
              -c 'lua assert(vim.g.loaded_vrv == 1); assert(require("vrv")); assert(require("telescope")); assert(require("plenary"))' \
              -c 'qa!'
            touch "$out"
          '';
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellApplication {
          name = "vrv-format";
          runtimeInputs = [
            pkgs.nixfmt
            pkgs.stylua
          ];
          text = ''
            nixfmt flake.nix
            stylua lua plugin tests
          '';
        }
      );
    };
}
