#version 450

layout (location = 1) out vec2 out_uv;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

uniform vec2 window_size;
uniform vec2 position;
uniform vec2 size;

uniform vec3 color;

uniform int mode;

vec3 planes[6] = vec3[](
    vec3(0.5, 0.5, 0), vec3(-0.5, 0.5, 0), vec3(-0.5, -0.5, 0),
    vec3(-0.5, -0.5, 0), vec3(0.5, -0.5, 0), vec3(0.5, 0.5, 0)
);
// Flipped on Y axis
vec2 uvs[6] = vec2[](
    vec2(1, 0), vec2(0, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 1), vec2(1, 0)
);

void main() {
  if (mode == 0) {
    vec3 p = planes[gl_VertexID];
    vec4 world_position = model * vec4(p, 1.0);
    gl_Position = projection * view * world_position;
  } else {
    vec2 p = planes[gl_VertexID].xy;
    vec2 scale = size / window_size;
    vec2 po = position / window_size;
    gl_Position = vec4(p * scale + po, 1.0, 1.0);
  }
  out_uv = uvs[gl_VertexID];
}
