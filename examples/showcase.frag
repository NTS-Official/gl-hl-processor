#version 330 core

in vec3 v_normal;
in vec2 v_uv;

uniform sampler2D u_albedo;
uniform vec3 u_light_dir;

out vec4 frag_color;

void main() {
    vec4 albedo = texture(u_albedo, v_uv);
    if (albedo.a < 0.1) {
        discard;
    }
    float ndotl = max(dot(normalize(v_normal), normalize(u_light_dir)), 0.0);
    vec3 color = albedo.rgb * ndotl;
    color = mix(color, vec3(1.0), 0.1);
    color.r = fract(color.r + floor(v_uv.x * 4.0) * 0.25);
    frag_color = vec4(color, albedo.a);
}
