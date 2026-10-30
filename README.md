# glsl2hlsl

用纯 Zig（0.17.0）实现的 GLSL 到 HLSL 转换库。不依赖 shaderc、spirv-cross 或 DXC，直接对 GLSL 源码做预处理、词法分析、语法分析和带类型推断的 HLSL 生成。

库提供 C ABI 和头文件式 C++17 封装。当前为第一阶段，覆盖常见的顶点/片元着色器写法：uniform 与采样器、stage 输入输出、矩阵与向量构造、常用内置函数、纹理采样和流程控制。

## 构建

```powershell
zig build -Doptimize=ReleaseSafe
```

产物：

| 路径 | 内容 |
| --- | --- |
| `zig-out\lib\glsl2hlsl.lib` | 静态库 |
| `zig-out\include\glsl2hlsl\glsl2hlsl.h` | C 头文件 |
| `zig-out\include\glsl2hlsl\glsl2hlsl.hpp` | C++ 头文件 |

需要动态库用 `-Dshared=true`，需要命令行工具用 `-Dcli=true`。接口与链接方式见 [docs/cpp-api.md](docs/cpp-api.md)。

## 使用

```cpp
#include <glsl2hlsl/glsl2hlsl.hpp>

glsl2hlsl::Result result = glsl2hlsl::convert(source, glsl2hlsl::Stage::Fragment);
if (!result) {
    for (const auto &diagnostic : result.diagnostics) {
        // diagnostic.line / column / message
    }
}
std::cout << result.output;
```

命令行工具：

```powershell
zig build -Dcli=true
.\zig-out\bin\glsl2hlsl.exe shader.vert
.\zig-out\bin\glsl2hlsl.exe shader.frag -o shader.hlsl -s fragment
```

## 文档

- [docs/README.md](docs/README.md)：项目概览与目录结构
- [docs/usage.md](docs/usage.md)：命令行、阶段推断与 Zig API
- [docs/cpp-api.md](docs/cpp-api.md)：C ABI、C++ 封装、链接与内存管理
- [docs/design.md](docs/design.md)：实现结构与设计取舍
- [docs/glsl-hlsl-mapping.md](docs/glsl-hlsl-mapping.md)：逐项映射规则

## 测试

```powershell
zig build test
zig build cpp-test
powershell -File tests/run.ps1
```

`tests/run.ps1` 以 `-Dcli=true` 构建命令行工具，转换 `tests/shaders` 与 `examples` 下的着色器，并在找到 `dxc.exe` 时编译生成的 HLSL。

## 限制

第一阶段不支持 UBO、几何/细分/计算着色器、函数重载、矩阵动态索引和图像原子操作等。详见映射文档的“不支持的特性”一节。
