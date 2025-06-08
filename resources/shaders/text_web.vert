#version 100
precision mediump float;

attribute vec3 in_position;
attribute vec2 in_uv;

varying vec2 f_uv;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

uniform vec3 color;

void main() {
    vec3 position = in_position;
    vec4 world_position = model * vec4(position, 1.0);
    gl_Position = projection * view * world_position;
    f_uv = in_uv;
}
