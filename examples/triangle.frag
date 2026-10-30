#version 330 core

in vec3 v_normal;
in vec2 v_uv;

uniform sampler2D u_albedo;
uniform vec3 u_light_dir;

out vec4 frag_color;

void main() {
    vec4 albedo = texture(u_albedo, v_uv);
    float ndotl = max(dot(normalize(v_normal), normalize(u_light_dir)), 0.0);
    frag_color = vec4(albedo.rgb * ndotl, albedo.a);
}
