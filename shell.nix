{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  SDL3_INCLUDE_PATH = "${pkgs.lib.makeIncludePath [pkgs.sdl3]}";
  LIBGL_INCLUDE_PATH = "${pkgs.lib.makeIncludePath [pkgs.libGL]}";

  buildInputs = with pkgs; [
    sdl3
    libGL
    pkg-config
    shaderc
  ];
}
