#version 100
precision mediump float;

attribute vec3 in_position;

varying vec3 f_near;
varying vec3 f_far;

uniform mat4 inverse_projection;
uniform mat4 inverse_view;

vec3 clip_to_world(vec3 point) {
  mat4 inv_view = inverse_view;
  mat4 inv_proj = inverse_projection;
  vec4 world = inv_view * inv_proj * vec4(point, 1.0);
  return world.xyz / world.w;
}

void main() {
    vec3 point = in_position;
    vec3 world_near = clip_to_world(vec3(point.xy, 1.0));
    vec3 world_far = clip_to_world(vec3(point.xy, 0.0));

    f_near = world_near;
    f_far = world_far;
    gl_Position = vec4(in_position, 1.0);
}
