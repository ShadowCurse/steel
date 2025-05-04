#version 100
precision mediump float;

varying vec4 frag_color;

void main() {
    gl_FragColor = abs(frag_color);
}
