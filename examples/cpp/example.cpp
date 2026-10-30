#include <glsl2hlsl/glsl2hlsl.hpp>

#include <iostream>
#include <string_view>

int main() {
    constexpr std::string_view source =
        "#version 330 core\n"
        "in vec2 v_uv;\n"
        "uniform sampler2D u_albedo;\n"
        "out vec4 frag_color;\n"
        "void main() {\n"
        "    vec4 albedo = texture(u_albedo, v_uv);\n"
        "    frag_color = vec4(albedo.rgb * 0.5, 1.0);\n"
        "}\n";

    const glsl2hlsl::Result result = glsl2hlsl::convert(source, glsl2hlsl::Stage::Fragment);

    for (const glsl2hlsl::Diagnostic &diagnostic : result.diagnostics) {
        std::cerr << glsl2hlsl::to_string(diagnostic.severity) << ":" << diagnostic.line
                  << ":" << diagnostic.column << ": " << diagnostic.message << "\n";
    }

    if (!result) {
        return 1;
    }

    std::cout << result.output;
    return 0;
}
