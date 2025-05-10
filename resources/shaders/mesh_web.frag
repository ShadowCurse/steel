#version 100
precision mediump float;

varying vec3 f_position;
varying vec3 f_normal;
varying vec2 f_uv;

uniform vec3 color;
uniform vec3 camera_position;
uniform vec3 light_position;

void main() {
    vec3 to_light = normalize(light_position - f_position);
    vec3 to_camera = normalize(camera_position - f_position);
    vec3 light_reflect = reflect(-to_light, f_normal);
    vec3 half_way = normalize(to_light + to_camera);

    vec3 ambient = 0.05 * color;

    float diffuse_strength = max(dot(to_light, f_normal), 0.0);
    vec3 diffuse = diffuse_strength * color;

    float spec_strength = pow(max(dot(f_normal, half_way), 0.0), 32.0);
    vec3 spec = vec3(0.2) * spec_strength;

    gl_FragColor = vec4(ambient + diffuse + spec, 1.0);
}
