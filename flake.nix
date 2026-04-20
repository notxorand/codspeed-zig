{
  description = "CodSpeed instrument hooks development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        commonBuildInputs = with pkgs; [
          zigpkgs."0.16.0"
          just
          clang
          cmake
          bazelisk
          python3
        ];

      in
      {
        devShells = {
          default = pkgs.mkShell {
            buildInputs = commonBuildInputs;
            shellHook = ''
              echo "Instrument hooks development environment"
            '';
          };

          lsp = pkgs.mkShell {
            buildInputs =
              with pkgs;
              [
                zls
                clang-tools
              ]
              ++ commonBuildInputs;
            shellHook = ''
              echo "Instrument hooks development environment with LSP"
            '';
          };
        };
      }
    );
}
