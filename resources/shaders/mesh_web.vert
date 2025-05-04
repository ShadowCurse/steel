#version 100
precision mediump float;

attribute vec3 in_position;
attribute float in_uv_x;
attribute vec3 in_normal;
attribute float in_uv_y;
attribute vec4 in_color;

varying vec4 frag_color;
varying vec3 normal;
varying vec2 uv;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

void main() {
    gl_Position = projection * view * model * vec4(in_position, 1.0);
    frag_color = in_color;
    normal = in_normal;
    uv = vec2(in_uv_x, in_uv_y);
}
