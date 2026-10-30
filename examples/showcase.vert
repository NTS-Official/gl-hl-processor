#version 330 core

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec3 a_normal;

uniform mat4 u_mvp;
uniform mat4 u_normal;

out vec3 v_normal;
out vec2 v_uv;

const float SCALE = 2.0;

vec3 transform_normal(vec3 n) {
    return normalize((u_normal * vec4(n, 0.0)).xyz);
}

void main() {
    vec3 p = a_position * SCALE;
    gl_Position = u_mvp * vec4(p, 1.0);
    v_normal = transform_normal(a_normal);
    v_uv = vec2(a_position.x, a_position.y) * 0.5 + 0.5;
}
