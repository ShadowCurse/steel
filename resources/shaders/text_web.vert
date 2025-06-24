#version 100
precision mediump float;

attribute vec3 in_position;
attribute vec2 in_uv;

varying vec2 f_uv;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

uniform vec2 window_size;
uniform vec2 position;
uniform vec2 size;

uniform vec3 color;

uniform int mode;

void main() {
  if (mode == 0) {
    vec3 p = in_position;
    vec4 world_position = model * vec4(p, 1.0);
    gl_Position = projection * view * world_position;
  } else {
    vec2 p = in_position.xy;
    vec2 scale = size / window_size;
    vec2 po = position / window_size;
    gl_Position = vec4(p * scale + po, 1.0, 1.0);
  }
  f_uv = in_uv;
}
