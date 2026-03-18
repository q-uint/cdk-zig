{
  description = "devenv";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }: flake-utils.lib.eachDefaultSystem (
    system:
    let
      pkgs = import nixpkgs { inherit system; };

      icpCliSrc =
        if system == "x86_64-linux" then
          {
            url = "https://github.com/dfinity/icp-cli/releases/download/v0.2.1/icp-cli-x86_64-unknown-linux-gnu.tar.xz";
            sha256 = "0ny27xycf2pwvrd3lj37dpza8j2ywqdb7p3fiylkg9iyicns43vv";
          }
        else if system == "aarch64-linux" then
          {
            url = "https://github.com/dfinity/icp-cli/releases/download/v0.2.1/icp-cli-aarch64-unknown-linux-gnu.tar.xz";
            sha256 = "0175agj03ksv3pajv8hacrgvm5rvdlz9029nvx9l9la3rny664j3";
          }
        else if system == "x86_64-darwin" then
          {
            url = "https://github.com/dfinity/icp-cli/releases/download/v0.2.1/icp-cli-x86_64-apple-darwin.tar.xz";
            sha256 = "04r41fxniy25kszgp0v1rv1yg9nnaq8kyyr4qwbf1a4dwp5ykz3c";
          }
        else if system == "aarch64-darwin" then
          {
            url = "https://github.com/dfinity/icp-cli/releases/download/v0.2.1/icp-cli-aarch64-apple-darwin.tar.xz";
            sha256 = "0ghb9g45g1r1rc0lls4c8cwax2pkzqrqmb3f7dbq7nyc7f6brhwd";
          }
        else
          { };

      icp-cli = pkgs.stdenv.mkDerivation {
        name = "icp-cli-${system}";
        src = pkgs.fetchurl icpCliSrc;

        dontUnpack = true;

        nativeBuildInputs = [
          pkgs.xz
        ];

        installPhase = ''
          mkdir -p $out/bin
          tar -xJf $src
          cp */icp $out/bin/
        '';
      };
    in
    {
      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [
          # ic
          icp-cli

          # zig
          zig-overlay.packages.${system}."0.15.2"
          zls
        ];
      };
    }
  );
}
