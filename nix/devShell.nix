{
  mkShell,
  alejandra,
  doxygen,
  git,
  nodePackages,
  pkg-config,
  zig,
  zon2nix,
}:
mkShell {
  name = "libghostty-vt";
  packages = [
    zig
    git
    pkg-config
    doxygen
    zon2nix
    alejandra
    nodePackages.prettier
  ];
}
