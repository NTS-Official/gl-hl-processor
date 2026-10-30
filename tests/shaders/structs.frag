#version 330 core

struct Material {
    vec3 albedo;
    float roughness;
};

uniform Material u_material;
uniform vec4 u_tint;
uniform int u_mode;

in vec2 v_uv;

out vec4 frag_color;

void main() {
    vec3 color = u_material.albedo * u_tint.rgb;
    switch (u_mode) {
        case 0:
            color = u_material.albedo;
            break;
        case 1:
            color = u_tint.rgb;
            break;
        default:
            color = vec3(1.0);
            break;
    }
    frag_color = vec4(color, 1.0);
}
