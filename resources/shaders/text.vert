#version 450

layout (location = 1) out vec2 out_uv;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

uniform vec3 color;

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
    vec3 position = planes[gl_VertexID];
    vec4 world_position = model * vec4(position, 1.0);
    gl_Position = projection * view * world_position;
    out_uv = uvs[gl_VertexID];
}
