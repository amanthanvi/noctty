{
  mkShell,
  alejandra,
  doxygen,
  nodePackages,
  zig,
  zon2nix,
}:
mkShell {
  name = "libghostty-vt";
  packages = [
    zig
    doxygen
    zon2nix
    alejandra
    nodePackages.prettier
  ];
}
