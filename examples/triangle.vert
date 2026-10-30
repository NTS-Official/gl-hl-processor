#version 330 core

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_normal;

uniform mat4 u_mvp;
uniform mat4 u_model;

out vec3 v_normal;
out vec2 v_uv;

void main() {
    gl_Position = u_mvp * vec4(a_position, 1.0);
    v_normal = (u_model * vec4(a_normal, 0.0)).xyz;
    v_uv = a_uv;
}
