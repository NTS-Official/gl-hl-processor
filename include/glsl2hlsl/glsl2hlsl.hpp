#ifndef GLSL2HLSL_HPP
#define GLSL2HLSL_HPP

#include "glsl2hlsl.h"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace glsl2hlsl {

enum class Stage {
    Auto = GLSL2HLSL_STAGE_AUTO,
    Vertex = GLSL2HLSL_STAGE_VERTEX,
    Fragment = GLSL2HLSL_STAGE_FRAGMENT
};

enum class Status {
    Ok = GLSL2HLSL_STATUS_OK,
    InvalidShader = GLSL2HLSL_STATUS_INVALID_SHADER,
    OutOfMemory = GLSL2HLSL_STATUS_OUT_OF_MEMORY,
    InvalidArgument = GLSL2HLSL_STATUS_INVALID_ARGUMENT
};

enum class Severity {
    Error = GLSL2HLSL_SEVERITY_ERROR,
    Warning = GLSL2HLSL_SEVERITY_WARNING
};

struct Diagnostic {
    Severity severity = Severity::Error;
    std::uint32_t line = 0;
    std::uint32_t column = 0;
    std::string message;
};

struct Result {
    Status status = Status::InvalidArgument;
    std::string output;
    std::vector<Diagnostic> diagnostics;

    bool ok() const noexcept { return status == Status::Ok; }
    explicit operator bool() const noexcept { return ok(); }
};

inline const char *to_string(Status status) noexcept {
    switch (status) {
    case Status::Ok:
        return "ok";
    case Status::InvalidShader:
        return "invalid shader";
    case Status::OutOfMemory:
        return "out of memory";
    case Status::InvalidArgument:
        return "invalid argument";
    }
    return "unknown";
}

inline const char *to_string(Severity severity) noexcept {
    switch (severity) {
    case Severity::Error:
        return "error";
    case Severity::Warning:
        return "warning";
    }
    return "unknown";
}

namespace detail {

struct ResultOwner {
    glsl2hlsl_result value{};

    ResultOwner() = default;
    ResultOwner(const ResultOwner &) = delete;
    ResultOwner &operator=(const ResultOwner &) = delete;

    ~ResultOwner() { glsl2hlsl_result_free(&value); }
};

}

inline Result convert(std::string_view source, Stage stage = Stage::Auto) {
    detail::ResultOwner owner;
    const char *data = source.empty() ? "" : source.data();
    const glsl2hlsl_status status = glsl2hlsl_convert(
        data,
        source.size(),
        static_cast<glsl2hlsl_stage>(stage),
        &owner.value);

    Result result;
    result.status = static_cast<Status>(status);

    if (owner.value.output != nullptr) {
        result.output.assign(owner.value.output, owner.value.output_length);
    }

    result.diagnostics.reserve(owner.value.diagnostic_count);
    for (size_t i = 0; i < owner.value.diagnostic_count; ++i) {
        const glsl2hlsl_diagnostic &raw = owner.value.diagnostics[i];
        const char *message = raw.message != nullptr ? raw.message : "";
        result.diagnostics.push_back(Diagnostic{
            static_cast<Severity>(raw.severity),
            raw.line,
            raw.column,
            std::string(message, raw.message_length)});
    }

    return result;
}

inline const char *version() noexcept {
    return glsl2hlsl_version();
}

}

#endif
