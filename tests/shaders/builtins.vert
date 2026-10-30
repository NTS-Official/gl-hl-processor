#version 330 core

uniform mat4 u_mvp;

void main() {
    float id = float(gl_VertexID);
    float instance = float(gl_InstanceID);
    vec3 p = vec3(id * 0.001, instance * 0.001, 0.0);
    gl_Position = u_mvp * vec4(p, 1.0);
}
