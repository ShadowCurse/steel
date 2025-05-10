#version 100
precision mediump float;

attribute vec3 in_position;
attribute float in_uv_x;
attribute vec3 in_normal;
attribute float in_uv_y;
attribute vec4 in_color;

varying vec3 f_position;
varying vec3 f_normal;
varying vec2 f_uv;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

void main() {
    vec4 world_position = model * vec4(in_position, 1.0);
    gl_Position = projection * view * world_position;
    f_position = world_position.xyz;
    f_normal = in_normal;
    f_uv = vec2(in_uv_x, in_uv_y);
}
