#version 100
precision mediump float;

varying vec2 f_uv;

uniform vec3 color;
uniform vec2 uv_scale;
uniform vec2 uv_offset;

uniform sampler2D font_texture;

void main() {
    vec2 size = vec2(512, 512);

    vec2 uv_offset = uv_offset / size;
    vec2 uv_scale = uv_scale / size;

    float a = texture2D(font_texture, f_uv * uv_scale + uv_offset).a;
    vec3 c = color * a;
    gl_FragColor = vec4(c, a);
}
