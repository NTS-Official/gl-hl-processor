#version 330 core

layout(location = 0) in vec3 a_position;

uniform mat4 u_mvp;

out vec2 v_uv;

void main() {
    mat3 rotation = mat3(0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0);
    mat3 identity = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0));
    vec3 p = rotation * a_position;
    p = identity * p;
    gl_Position = u_mvp * vec4(p, 1.0);
    v_uv = a_position.xy;
}
