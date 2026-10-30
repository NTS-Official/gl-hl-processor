#include <glsl2hlsl/glsl2hlsl.h>

#include <stdio.h>
#include <string.h>

static int contains(const char *text, const char *needle) {
    return strstr(text, needle) != nullptr;
}

int main(void) {
    const char *vertex_source =
        "#version 330 core\n"
        "layout(location = 0) in vec3 a_position;\n"
        "uniform mat4 u_mvp;\n"
        "void main() {\n"
        "    gl_Position = u_mvp * vec4(a_position, 1.0);\n"
        "}\n";

    int failures = 0;
    glsl2hlsl_result result = {};

    glsl2hlsl_status status = glsl2hlsl_convert(
        vertex_source,
        strlen(vertex_source),
        GLSL2HLSL_STAGE_VERTEX,
        &result);

    if (status != GLSL2HLSL_STATUS_OK) {
        fprintf(stderr, "FAIL: vertex conversion returned %d\n", (int)status);
        failures += 1;
    } else {
        if (!contains(result.output, "cbuffer Globals")) {
            fprintf(stderr, "FAIL: missing cbuffer\n");
            failures += 1;
        }
        if (!contains(result.output, "SV_Position")) {
            fprintf(stderr, "FAIL: missing SV_Position\n");
            failures += 1;
        }
    }
    glsl2hlsl_result_free(&result);

    const char *invalid_source = "void main() { gl_Position = ; }";
    status = glsl2hlsl_convert(
        invalid_source,
        strlen(invalid_source),
        GLSL2HLSL_STAGE_AUTO,
        &result);

    if (status != GLSL2HLSL_STATUS_INVALID_SHADER) {
        fprintf(stderr, "FAIL: invalid shader returned %d\n", (int)status);
        failures += 1;
    }
    if (result.diagnostic_count == 0 || result.diagnostics == nullptr) {
        fprintf(stderr, "FAIL: missing diagnostics\n");
        failures += 1;
    }
    glsl2hlsl_result_free(&result);

    if (failures == 0) {
        printf("c interop ok\n");
    }
    return failures == 0 ? 0 : 1;
}
