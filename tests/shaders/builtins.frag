#version 330 core

uniform sampler2D u_tex;

out vec4 frag_color;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    vec4 c = texture(u_tex, uv);
    if (!gl_FrontFacing) {
        c = vec4(0.0);
    }
    gl_FragDepth = gl_FragCoord.z;
    frag_color = c;
}
