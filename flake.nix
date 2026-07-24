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
            url = "https://github.com/dfinity/pocketic/releases/download/15.0.0/pocket-ic-x86_64-linux.gz";
            sha256 = "0f5hh94xsnfkh6nbh4prdrklq14sdzni8m2vn13g1l5xfllmjbcp";
          }
        else if system == "aarch64-linux" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/15.0.0/pocket-ic-arm64-linux.gz";
            sha256 = "1nxjnsqwmncph9qbhsabag08f9s20hjdgs7dd3ariq9n81whvl0r";
          }
        else if system == "x86_64-darwin" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/15.0.0/pocket-ic-x86_64-darwin.gz";
            sha256 = "0wlz7zbi3w8rbjwhlnkk45b7mhlhlpkyc21dbbi8r3lcq03kl4qx";
          }
        else if system == "aarch64-darwin" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/15.0.0/pocket-ic-arm64-darwin.gz";
            sha256 = "03parxzqgisb941lqw5v2rcvfcp128jmczw724a0jjcraps6vag6";
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
          zig-overlay.packages.${system}."0.16.0"
          zls

          # profiling
          flamegraph
        ];

        POCKET_IC_BIN = "${pocket-ic-server}/bin/pocket-ic-server";
      };
    }
  );
}
