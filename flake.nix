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

      pocketIcSrc =
        if system == "x86_64-linux" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/12.0.0/pocket-ic-x86_64-linux.gz";
            sha256 = "1b25vf5vvpz07b7wyw59jda1lxr7b4zv8gwhsln41a785yhmnh4i";
          }
        else if system == "aarch64-linux" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/12.0.0/pocket-ic-arm64-linux.gz";
            sha256 = "058bwjaqf9la037g72lfx0gw6g4ljcri9c209x70hihiw95aqb2x";
          }
        else if system == "x86_64-darwin" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/12.0.0/pocket-ic-x86_64-darwin.gz";
            sha256 = "0dcyh74c696lqjnlh1bzjh8x0xqgsvcqivqlbs9sifmgqipsbfk7";
          }
        else if system == "aarch64-darwin" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/12.0.0/pocket-ic-arm64-darwin.gz";
            sha256 = "0wsqb6575ydq8190h4z11r8ssgbm1smvc7n0scyl05j5zrcqbmab";
          }
        else
          { };

      pocket-ic-server = pkgs.stdenv.mkDerivation {
        name = "pocket-ic-server-${system}";
        src = pkgs.fetchurl pocketIcSrc;

        dontUnpack = true;

        nativeBuildInputs = [
          pkgs.gzip
        ];

        installPhase = ''
          mkdir -p $out/bin
          gunzip -c $src > $out/bin/pocket-ic-server
          chmod +x $out/bin/pocket-ic-server
        '';
      };

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
          pocket-ic-server

          # zig
          zig-overlay.packages.${system}."0.15.2"
          zls
        ];

        POCKET_IC_BIN = "${pocket-ic-server}/bin/pocket-ic-server";
      };
    }
  );
}
