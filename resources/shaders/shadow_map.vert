#version 450

layout (location = 0) in vec3 in_position;
layout (location = 1) in float in_uv_x;
layout (location = 2) in vec3 in_normal;
layout (location = 3) in float in_uv_y;
layout (location = 4) in vec4 in_color;

uniform mat4 projection;
uniform mat4 view;
uniform mat4 model;

void main() {
    vec4 world_position = model * vec4(in_position, 1.0);
    gl_Position = projection * view * world_position;
}
