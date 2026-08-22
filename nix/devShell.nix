{mkShell, doxygen, zig}:
mkShell {
  name = "libghostty-vt";
  packages = [
    zig
    doxygen
  ];
}
