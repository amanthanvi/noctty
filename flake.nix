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

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        systems.follows = "systems";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    zig,
    ...
  }: let
    inherit (nixpkgs) lib legacyPackages;

    # Our supported systems are the same supported systems as the Zig binaries.
    platforms = lib.attrNames zig.packages;

    # libghostty-vt currently installs ELF shared-library outputs, so do not
    # expose the package derivation on Darwin.
    buildablePlatforms = lib.filter (p: !(lib.systems.elaborate p).isDarwin) platforms;

    forAllPlatforms = f: lib.genAttrs platforms (s: f legacyPackages.${s});
    forBuildablePlatforms = f: lib.genAttrs buildablePlatforms (s: f legacyPackages.${s});

    zigFor = pkgs: zig.packages.${pkgs.stdenv.hostPlatform.system}."0.15.2";

    mkPkgArgs = pkgs: optimize: {
      inherit optimize;
      revision = self.shortRev or self.dirtyShortRev or "dirty";
      zig_0_15 = zigFor pkgs;
    };
  in {
    devShells = forAllPlatforms (pkgs: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zigFor pkgs;
      };
    });

    packages = forBuildablePlatforms (pkgs: rec {
      libghostty-vt-debug = pkgs.callPackage ./nix/libghostty-vt.nix (mkPkgArgs pkgs "Debug");
      libghostty-vt-releasesafe = pkgs.callPackage ./nix/libghostty-vt.nix (mkPkgArgs pkgs "ReleaseSafe");
      libghostty-vt-releasefast = pkgs.callPackage ./nix/libghostty-vt.nix (mkPkgArgs pkgs "ReleaseFast");
      libghostty-vt-debug-no-simd = pkgs.callPackage ./nix/libghostty-vt.nix ((mkPkgArgs pkgs "Debug") // {simd = false;});
      libghostty-vt-releasesafe-no-simd = pkgs.callPackage ./nix/libghostty-vt.nix ((mkPkgArgs pkgs "ReleaseSafe") // {simd = false;});
      libghostty-vt-releasefast-no-simd = pkgs.callPackage ./nix/libghostty-vt.nix ((mkPkgArgs pkgs "ReleaseFast") // {simd = false;});

      libghostty-vt = libghostty-vt-releasefast;
      default = libghostty-vt;
    });
  };
}
