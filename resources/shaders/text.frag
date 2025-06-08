#version 450

layout (location = 0) out vec4 out_color;

layout (location = 1) in vec2 in_uv;

uniform vec3 color;
uniform vec2 uv_scale;
uniform vec2 uv_offset;

uniform sampler2D font_texture;

void main() {
    vec2 size = textureSize(font_texture, 0);

    vec2 uv_offset = uv_offset / size;
    vec2 uv_scale = uv_scale / size;

    float r = texture(font_texture, in_uv * uv_scale + uv_offset).r;
    vec3 c = color * r;
    out_color = vec4(c, r);
}
