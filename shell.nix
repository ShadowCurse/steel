{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  SDL3_INCLUDE_PATH = "${pkgs.lib.makeIncludePath [pkgs.sdl3]}";
  LIBGL_INCLUDE_PATH = "${pkgs.lib.makeIncludePath [pkgs.libGL]}";
  # on nixos the cache is readonly by default. Move it to the
  # home directory
  EM_CACHE="/home/antaraz/.emscripten_cache";

  buildInputs = with pkgs; [
    sdl3
    libGL
    pkg-config
    shaderc
    emscripten
  ];
}
