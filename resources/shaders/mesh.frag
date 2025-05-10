#version 450

layout (location = 0) out vec4 out_color;

layout (location = 5) in vec3 in_position;
layout (location = 6) in vec3 in_normal;

uniform vec3 color;
uniform vec3 camera_position;
uniform vec3 light_position;

void main() {
    vec3 to_light = normalize(light_position - in_position);
    vec3 to_camera = normalize(camera_position - in_position);
    vec3 light_reflect = reflect(-to_light, in_normal);
    vec3 half_way = normalize(to_light + to_camera);

    vec3 ambient = 0.05 * color;

    float diffuse_strength = max(dot(to_light, in_normal), 0.0);
    vec3 diffuse = diffuse_strength * color;

    float spec_strength = pow(max(dot(in_normal, half_way), 0.0), 32.0);
    vec3 spec = vec3(0.2) * spec_strength;

    out_color = vec4(ambient + diffuse + spec, 1.0);
}
