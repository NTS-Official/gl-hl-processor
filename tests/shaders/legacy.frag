#version 120

uniform sampler2D u_tex;
varying vec2 v_uv;

void main() {
    vec4 color = texture2D(u_tex, v_uv);
    if (color.a < 0.5) {
        discard;
    }
    gl_FragColor = color;
}
