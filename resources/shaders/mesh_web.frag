#version 100
precision mediump float;

varying vec3 f_position;
varying vec3 f_normal;
varying vec2 f_uv;

uniform vec3 camera_position;
uniform vec3 light_positions[1];
uniform vec3 light_colors[1];
uniform vec3 albedo;
uniform float metallic;
uniform float roughness;
uniform float ao;

const float PI = 3.14159265359;

vec3 fresnel_schlick(float cos_theta, vec3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}  

float distribution_ggx(vec3 normal, vec3 half_vector, float roughness) {
    float a        = roughness *  roughness;
    float a2       = a * a;
    float n_dot_h  = max(dot(normal, half_vector), 0.0);
    float n_dot_h2 = n_dot_h * n_dot_h;
	
    float num   = a2;
    float denom = (n_dot_h2 * (a2 - 1.0) + 1.0);
    denom       = PI * denom * denom;
	
    return num / denom;
}

float geometry_schlick_ggx(float d, float roughness) {
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;

    float num   = d;
    float denom = d * (1.0 - k) + k;
	
    return num / denom;
}
float geometry_smith(float ndl, float ndc, float roughness) {
    float ggx1 = geometry_schlick_ggx(ndl, roughness);
    float ggx2 = geometry_schlick_ggx(ndc, roughness);
    return ggx1 * ggx2;
}

void main() {
    vec3 normal = normalize(f_normal);
    vec3 to_camera = normalize(camera_position - f_position);

    vec3 base_reflectivity = vec3(0.04); 
    base_reflectivity = mix(base_reflectivity, albedo, metallic);
	           
    vec3 radiance_out = vec3(0.0);
    for(int i = 0; i < 1; ++i) {
        // calculate per-light radiance
        vec3 to_light     = normalize(light_positions[i] - f_position);
        vec3 half_vector  = normalize(to_camera + to_light);

        float ndl = max(dot(normal, to_light), 0.0);                
        float ndc = max(dot(normal, to_camera), 0.0);                
        float ndh = max(dot(half_vector, to_camera), 0.0);

        float distance    = length(light_positions[i] - f_position) / 5.0;
        float attenuation = 1.0 / (distance * distance);
        vec3 radiance     = light_colors[i] * attenuation;        
        
        // cook-torrance brdf
        float normalDF = distribution_ggx(normal, half_vector, roughness);        
        float G        = geometry_smith(ndl, ndc, roughness);      
        vec3 F         = fresnel_schlick(ndh, base_reflectivity);       
        
        vec3 kS = F;
        vec3 kD = vec3(1.0) - kS;
        kD *= 1.0 - metallic;	  
        
        vec3 numerator    = normalDF * G * F;
        float denominator = 4.0 * ndc * ndl + 0.0001;
        vec3 specular     = numerator / denominator;  
            
        // add to outgoing radiance
        radiance_out += (kD * albedo / PI + specular) * radiance * ndl; 
    }
  
    vec3 ambient = vec3(0.03) * albedo * ao;
    vec3 color = ambient + radiance_out;
	
    color = color / (color + vec3(1.0));
    color = pow(color, vec3(1.0 / 2.2));  
   
    gl_FragColor = vec4(color, 1.0);
}
