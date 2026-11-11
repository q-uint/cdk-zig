{
  description = "devenv";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem (
    system:
    let
      pkgs = import nixpkgs { inherit system; };

      pocketIcSrc =
        if system == "x86_64-linux" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/16.1.0/pocket-ic-x86_64-linux.gz";
            hash = "sha256-ExIZ2Q3Pm/bz7Y7gLY9VUE6iSm2zgvVoBnW3vWt+078=";
          }
        else if system == "aarch64-linux" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/16.1.0/pocket-ic-arm64-linux.gz";
            hash = "sha256-g+Fu+Syvq1oLFVuNuGjCgZG5KRXk+6BMdlRMygkIGrE=";
          }
        else if system == "x86_64-darwin" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/16.1.0/pocket-ic-x86_64-darwin.gz";
            hash = "sha256-r5rS14FTCkNVbvLRyPk9uZokJcbKvceFIPYZIjme1TA=";
          }
        else if system == "aarch64-darwin" then
          {
            url = "https://github.com/dfinity/pocketic/releases/download/16.1.0/pocket-ic-arm64-darwin.gz";
            hash = "sha256-muhD+7eubG6zATdnHIYpqA71Ozo2UuuFs0SEesOfn80=";
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
    in
    {
      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [
          # ic
          pocket-ic-server

          # zig
          zig
          zls

          # profiling
          flamegraph
        ];

        POCKET_IC_BIN = "${pocket-ic-server}/bin/pocket-ic-server";
      };
    }
  );
}
