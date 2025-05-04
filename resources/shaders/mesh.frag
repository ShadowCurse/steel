#version 450

layout (location = 5) in vec4 in_color;

layout (location = 0) out vec4 out_color;

void main() {
    out_color = abs(in_color);
}
