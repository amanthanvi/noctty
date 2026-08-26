{
  description = "libghostty-vt for noctty";

  inputs = {
    # Keep Zig and glibc versions compatible with the systems consuming the
    # libghostty-vt package.
    #
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    systems = {
      url = "github:nix-systems/default";
      flake = false;
    };

    zon2nix = {
      url = "github:jcollie/zon2nix?rev=c28e93f3ba133d4c1b1d65224e2eebede61fd071";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    systems,
    zon2nix,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;

    platforms = import systems;

    # libghostty-vt currently installs ELF shared-library outputs, so do not
    # expose the package derivation on Darwin.
    buildablePlatforms = lib.filter (p: !(lib.systems.elaborate p).isDarwin) platforms;

    forAllPlatforms = f: lib.genAttrs platforms (s: f legacyPackages.${s});
    forBuildablePlatforms = f: lib.genAttrs buildablePlatforms (s: f legacyPackages.${s});

    mkPkgArgs = optimize: {
      inherit optimize;
      revision = self.shortRev or self.dirtyShortRev or "dirty";
    };
  in {
    devShells = forAllPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = pkgs.zig_0_15;
        zon2nix = zon2nix.packages.${pkgs.stdenv.hostPlatform.system}.zon2nix;
      };
    });

    packages = forBuildablePlatforms (pkgs: rec {
      libghostty-vt-debug = pkgs.callPackage ./nix/libghostty-vt.nix (mkPkgArgs "Debug");
      libghostty-vt-releasesafe = pkgs.callPackage ./nix/libghostty-vt.nix (mkPkgArgs "ReleaseSafe");
      libghostty-vt-releasefast = pkgs.callPackage ./nix/libghostty-vt.nix (mkPkgArgs "ReleaseFast");
      libghostty-vt-debug-no-simd = pkgs.callPackage ./nix/libghostty-vt.nix ((mkPkgArgs "Debug") // {simd = false;});
      libghostty-vt-releasesafe-no-simd = pkgs.callPackage ./nix/libghostty-vt.nix ((mkPkgArgs "ReleaseSafe") // {simd = false;});
      libghostty-vt-releasefast-no-simd = pkgs.callPackage ./nix/libghostty-vt.nix ((mkPkgArgs "ReleaseFast") // {simd = false;});

      libghostty-vt = libghostty-vt-releasefast;
      default = libghostty-vt;
    });
  };
}
