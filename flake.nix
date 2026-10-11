{
  description = "ghost.nvim: Copilot-style ghost text from a local llama.cpp model";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The plugin plus everything it needs: llama.cpp's server, curl and a
      # pinned code model. Used via callPackage, so `.override { ... }` works.
      ghost =
        {
          lib,
          vimUtils,
          writeShellApplication,
          writeText,
          fetchurl,
          llama-cpp,
          curl,

          # Any GGUF model trained for fill-in-the-middle (Qwen2.5-Coder,
          # StarCoder2, DeepSeek-Coder, Codestral...). The default is ~1.6 GB.
          model ? fetchurl {
            name = "qwen2.5-coder-1.5b-q8_0.gguf";
            url = "https://huggingface.co/ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF/resolve/main/qwen2.5-coder-1.5b-q8_0.gguf";
            sha256 = "29871c94d15727a6e243f79a37113d4ae625a6215b5e800bf41a23af2da32832";
          },
          port ? 8012,
          # Appended to the llama-server command line.
          extraServerArgs ? [ ],
        }:
        let
          serverArgs = [
            "--model"
            "${model}"
            "--host"
            "127.0.0.1"
            "--port"
            (toString port)
            "--ctx-size"
            "8192"
            "--batch-size"
            "1024"
            "--ubatch-size"
            "1024"
            "--cache-reuse"
            "256"
            "--n-gpu-layers"
            "99" # ignored by CPU-only builds
          ]
          ++ extraServerArgs;

          # Runs llama-server and kills it as soon as the Neovim that started
          # it goes away, even if Neovim crashes or is SIGKILLed.
          ghost-server = writeShellApplication {
            name = "ghost-server";
            runtimeInputs = [ llama-cpp ];
            text = ''
              parent="''${1:-$PPID}"

              # Our current parent PID. When Neovim dies we get reparented,
              # which (unlike `kill -0`) also catches a zombie Neovim.
              ppid_now() {
                if [ -r "/proc/$$/stat" ]; then
                  local stat
                  read -r stat < "/proc/$$/stat"
                  stat="''${stat##*) }"
                  # shellcheck disable=SC2086
                  set -- $stat
                  echo "$2"
                else
                  ps -o ppid= -p "$$" | tr -d ' '
                fi
              }

              llama-server ${lib.escapeShellArgs serverArgs} &
              child=$!

              trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true' EXIT
              trap 'exit 0' INT TERM HUP

              while [ "$(ppid_now)" = "$parent" ] && kill -0 "$child" 2>/dev/null; do
                sleep 1
              done
            '';
          };

          # Store paths the Lua side reads via require("ghost.nix").
          nixLua = writeText "ghost-nix.lua" ''
            return {
              server_cmd = { "${lib.getExe ghost-server}" },
              pass_pid = true,
              curl = "${lib.getExe curl}",
              port = ${toString port},
            }
          '';
        in
        vimUtils.buildVimPlugin {
          pname = "ghost-nvim";
          version = "0.1.0";

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./lua
              ./plugin
            ];
          };

          postPatch = "cp ${nixLua} lua/ghost/nix.lua";

          passthru = { inherit ghost-server model nixLua; };

          meta = {
            description = "Copilot-style ghost text completions from a local llama.cpp model";
            license = lib.licenses.mit;
            platforms = lib.platforms.unix;
          };
        };
    in
    {
      packages = forAll (pkgs: rec {
        # CPU inference. Works everywhere, fine for a 1.5B model.
        default = pkgs.callPackage ghost { };

        # GPU via Vulkan: AMD, Intel and NVIDIA, nothing unfree.
        # May compile llama.cpp locally if the binary cache lacks this variant.
        vulkan = default.override {
          llama-cpp = pkgs.llama-cpp.override { vulkanSupport = true; };
        };
      });

      # Adds pkgs.vimPlugins.ghost-nvim, built from *your* nixpkgs, so your
      # config.cudaSupport / rocmSupport / allowUnfree settings apply.
      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins.extend (_: _: { ghost-nvim = final.callPackage ghost { }; });
      };

      # `direnv allow` (or `nix develop`) in the repo.
      devShells = forAll (
        pkgs:
        let
          plugin = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

          # Your normal Neovim, but loading the plugin straight from this
          # checkout, so edits take effect on restart without a rebuild.
          ghost-dev = pkgs.writeShellApplication {
            name = "ghost-dev";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              root="''${GHOST_DEV_ROOT:-$PWD}"
              exec nvim \
                --cmd "set rtp^=$root" \
                --cmd "lua package.preload['ghost.nix'] = function() return dofile('${plugin.nixLua}') end" \
                "$@"
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              ghost-dev
              plugin.ghost-server
              pkgs.neovim
              pkgs.curl
              pkgs.lua-language-server
              pkgs.stylua
              pkgs.nixfmt
            ];
            shellHook = ''
              export GHOST_DEV_ROOT="$PWD"
            '';
          };
        }
      );

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
