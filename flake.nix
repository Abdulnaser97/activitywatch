{
  description = "ActivityWatch — The free and open-source automated time tracker";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [ inputs.treefmt-nix.flakeModule ];

      perSystem =
        {
          config,
          pkgs,
          lib,
          system,
          ...
        }:
        let
          pythonVersion = "python312";
          pythonPkgs = pkgs.${pythonVersion}.pkgs;

          version = self.rev or self.dirtyRev or "dev";

          awSubmodules = [
            "aw-core"
            "aw-client"
            "aw-server"
            "aw-qt"
            "aw-watcher-afk"
            "aw-watcher-window"
          ];

          awExtras = [
            "aw-notify"
            "aw-watcher-input"
          ];

          src =
            let
              filesets = lib.fileset.unions (
                [ ./pyproject.toml ./poetry.lock ./Makefile ./aw.spec ]
                ++ map (name: ./${name}) (awSubmodules ++ awExtras)
              );
            in
            lib.fileset.toSource {
              root = ./.;
              fileset = filesets;
            };

          rustToolchain =
            let
              rustOverlay = inputs.rust-overlay.overlays.default;
              pkgsWithRust = import inputs.nixpkgs {
                inherit system;
                overlays = [ rustOverlay ];
              };
            in
            pkgsWithRust.rust-bin.stable.latest.default;

          aw-server-rust =
            if (builtins.pathExists ./aw-server-rust/Cargo.toml) then
              inputs.naersk.lib.${system}.buildPackage {
                root = ./aw-server-rust;
                src = lib.fileset.toSource {
                  root = ./aw-server-rust;
                  fileset = lib.fileset.unions [
                    ./aw-server-rust/Cargo.toml
                    ./aw-server-rust/Cargo.lock
                    ./aw-server-rust/src
                  ];
                };
                cargoBuildOptions = opts: opts ++ [ "--release" ];
                nativeBuildInputs = with pkgs; [ pkg-config ];
                buildInputs = with pkgs; [ openssl ];
              }
            else
              null;

          activitywatchPythonEnv = pkgs.${pythonVersion}.withPackages (ps: with ps; [
            urllib3
            pytest
            pytest-cov
            pytest-benchmark
            mypy
            psutil
          ]);

          runtimeDeps = with pkgs; [
            libsForQt5.qtbase
            libsForQt5.qtwayland
            libsForQt5.qtx11extras
            xorg.libxcb
            xorg.libX11
            xorg.libXcursor
            xorg.libXext
            xorg.libXfixes
            xorg.libXft
            xorg.libXi
            xorg.libXrandr
            xorg.libXrender
            fontconfig.lib
            freetype
          ];
        in
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              prettier.enable = true;
            };
          };

          packages =
            {
              default = pkgs.symlinkJoin {
                name = "activitywatch-${version}";
                paths = [
                  pkgs.${pythonVersion}
                  activitywatchPythonEnv
                ] ++ lib.optional (aw-server-rust != null) aw-server-rust;
                meta = with lib; {
                  description = "ActivityWatch — automated time tracker";
                  homepage = "https://activitywatch.net";
                  license = licenses.mpl20;
                  mainProgram = "aw-qt";
                  platforms = platforms.linux ++ platforms.darwin;
                };
              };
            }
            // lib.optionalAttrs (aw-server-rust != null) {
              aw-server-rust = aw-server-rust;
            };

          devShells = {
            default = pkgs.mkShell {
              packages =
                [
                  pkgs.${pythonVersion}
                ]
                ++ (
                  with pkgs;
                  [
                    poetry

                    # Node.js (for web UI)
                    nodejs_22

                    # Build tools
                    pkg-config
                    gcc

                    # Qt dependencies
                    libsForQt5.qtbase
                    libsForQt5.qtwayland
                    libsForQt5.qtx11extras

                    # X11/dev libraries
                    xorg.libxcb
                    xorg.libX11
                    xorg.libXcursor
                    xorg.libXext
                    xorg.libXfixes
                    xorg.libXft
                    xorg.libXi
                    xorg.libXrandr
                    xorg.libXrender
                    fontconfig.lib
                    freetype
                    openssl

                    # Linting & formatting
                    ruff
                    mypy

                    # Tools
                    git
                    jq
                  ]
                )
                ++ lib.optional (aw-server-rust != null) rustToolchain;

              LD_LIBRARY_PATH = lib.makeLibraryPath runtimeDeps;

              shellHook = ''
                echo "ActivityWatch dev shell (version: ${version})"
                echo "Python: $(python --version)"
                echo "Node: $(node --version)"
              '';
            };

            ci = pkgs.mkShellNoCC {
              packages = [
                pkgs.${pythonVersion}
              ] ++ (with pkgs; [
                poetry
                nodejs_22
                pkg-config
                gcc
                git
                jq
              ]);
            };
          };

          checks = {
            build = config.packages.default;

            format = config.treefmt.build.check self;

            devshell = config.devShells.default;
          };
        };

      flake.overlays.default = final: _prev: {
        activitywatch = final.symlinkJoin {
          name = "activitywatch-${final.lib.substring 0 7 (self.rev or self.dirtyRev or "dev")}";
          paths = [
            final.python312
            final.python312.withPackages (ps: with ps; [
              urllib3
              pytest
              pytest-cov
              mypy
            ])
          ];
          meta = with final.lib; {
            description = "ActivityWatch — automated time tracker";
            homepage = "https://activitywatch.net";
            license = licenses.mpl20;
            mainProgram = "aw-qt";
          };
        };
      };
    };
}
