#ifndef GLSL2HLSL_H
#define GLSL2HLSL_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(GLSL2HLSL_BUILD_DLL)
#define GLSL2HLSL_API __declspec(dllexport)
#else
#define GLSL2HLSL_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum glsl2hlsl_stage {
    GLSL2HLSL_STAGE_AUTO = 0,
    GLSL2HLSL_STAGE_VERTEX = 1,
    GLSL2HLSL_STAGE_FRAGMENT = 2
} glsl2hlsl_stage;

typedef enum glsl2hlsl_status {
    GLSL2HLSL_STATUS_OK = 0,
    GLSL2HLSL_STATUS_INVALID_SHADER = 1,
    GLSL2HLSL_STATUS_OUT_OF_MEMORY = 2,
    GLSL2HLSL_STATUS_INVALID_ARGUMENT = 3
} glsl2hlsl_status;

typedef enum glsl2hlsl_severity {
    GLSL2HLSL_SEVERITY_ERROR = 0,
    GLSL2HLSL_SEVERITY_WARNING = 1
} glsl2hlsl_severity;

typedef struct glsl2hlsl_diagnostic {
    glsl2hlsl_severity severity;
    uint32_t line;
    uint32_t column;
    char *message;
    size_t message_length;
} glsl2hlsl_diagnostic;

typedef struct glsl2hlsl_result {
    glsl2hlsl_status status;
    char *output;
    size_t output_length;
    glsl2hlsl_diagnostic *diagnostics;
    size_t diagnostic_count;
} glsl2hlsl_result;

GLSL2HLSL_API glsl2hlsl_status glsl2hlsl_convert(
    const char *source,
    size_t source_length,
    glsl2hlsl_stage stage,
    glsl2hlsl_result *result);

GLSL2HLSL_API void glsl2hlsl_result_free(glsl2hlsl_result *result);

GLSL2HLSL_API const char *glsl2hlsl_version(void);

#ifdef __cplusplus
}
#endif

#endif
