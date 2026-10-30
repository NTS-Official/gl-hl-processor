#version 330 core

in vec2 v_uv;
in vec3 v_color;

uniform sampler2D u_tex;
uniform sampler2D u_tex_b;
uniform vec4 u_tint;
uniform float u_weights[4];

out vec4 frag_color;

float weight_sum(int count) {
    float total = 0.0;
    for (int i = 0; i < count; i++) {
        total += u_weights[i];
    }
    return total;
}

void main() {
    vec2 uv = v_uv * 2.0 - 1.0;
    vec4 a = textureLod(u_tex, uv, 0.0);
    vec4 b = texelFetch(u_tex_b, ivec2(v_uv * 16.0), 0);
    vec3 c = mix(v_color, a.rgb, u_tint.a);
    float w = weight_sum(4);
    if (w > 100.0) {
        discard;
    }
    frag_color = vec4(c + b.rgb, 1.0);
}
