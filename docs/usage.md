# 用法

## 构建

需要 Zig 0.17.0。

```powershell
zig build -Doptimize=ReleaseSafe
```

默认产物是静态库 `zig-out\lib\glsl2hlsl.lib` 和 `zig-out\include\glsl2hlsl\` 下的头文件。动态库用 `-Dshared=true`。

本页的命令行用法需要显式构建命令行工具：

```powershell
zig build -Dcli=true -Doptimize=ReleaseSafe
```

可执行文件位于 `zig-out\bin\glsl2hlsl.exe`。

```powershell
zig build test
```

运行单元测试。测试覆盖词法分析、预处理器、语法分析、端到端生成和 C ABI。

## 命令行

```text
usage: glsl2hlsl [options] <input.glsl>

options:
  -o <path>              write HLSL to <path> instead of stdout
  -s, --stage <stage>    vertex or fragment (inferred when omitted)
  -h, --help             show this help
```

### 选项

| 选项 | 说明 |
| --- | --- |
| `-o <path>` | 将 HLSL 写入指定文件；省略时写到标准输出。父目录必须已存在。 |
| `-s`, `--stage <stage>` | 指定着色器阶段。接受 `vertex`、`vert`、`fragment`、`frag`。省略时自动推断。 |
| `-h`, `--help` | 打印帮助。 |

输入文件最大 16 MiB。

### 示例

```powershell
# 输出到标准输出
.\zig-out\bin\glsl2hlsl.exe examples\triangle.vert

# 写入文件，并显式指定阶段
.\zig-out\bin\glsl2hlsl.exe examples\triangle.frag -s fragment -o triangle_ps.hlsl

# 从管道读取暂不支持；输入必须是文件路径
```

## 阶段推断

未指定 `--stage` 时，转换器扫描整个翻译单元：

- 出现 `gl_Position`、`gl_VertexID` 或 `gl_InstanceID` → 顶点着色器。
- 出现 `gl_FragCoord`、`gl_FrontFacing`、`gl_FragColor`、`gl_FragDepth`、`discard`，或存在采样器 uniform → 片元着色器。
- 两类同时出现 → 报错。
- 两类都没有 → 给出警告并按片元着色器处理。

只有 `in` / `out` 声明、既没有系统内置变量也没有采样器的着色器无法自动判断，此时应使用 `--stage`。采样器启发式会让“既写 `gl_Position` 又采样纹理”的顶点着色器同时命中两类特征而报错，这种情况必须显式指定 `--stage vertex`。

显式指定阶段后仍会校验阶段相关的内置变量。例如对片元着色器使用 `--stage vertex`，若其中没有写 `gl_Position`，会报错 `vertex shader does not write gl_Position`。

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 转换成功，可能带警告。 |
| `1` | GLSL 或转换错误。诊断信息写到 stderr，不产生输出文件。 |
| `2` | 命令行参数或文件读写错误，例如缺少输入文件、未知选项、无法读取输入。 |

诊断格式：

```text
path\to\shader.frag:12:9: error: intrinsic 'inverse' is not supported
path\to\shader.frag:1:1: warning: could not infer shader stage; assuming fragment
```

行号、列号均从 1 开始。

## 生成代码的约定

- 入口函数固定命名为 `main`。
- 顶点着色器入口签名为 `VSOutput main(VSInput input)`；没有输入时无参数。
- 片元着色器有输出时返回 `PSOutput`，否则为 `void main(PSInput input)`。
- 非采样器 uniform 放入 `cbuffer Globals : register(b0)`，字段顺序与 GLSL 声明顺序一致。
- 采样器 uniform 生成 `Texture*`（`t0`、`t1`……）和 `SamplerState name_sampler`（`s0`、`s1`……）。buffer 采样器只占 `t` 寄存器。
- 顶点输入语义优先按变量名推断（`position`、`normal`、`tangent`、`color` 等），其次使用 `layout(location=N)`，否则按声明顺序分配 `TEXCOORDn`。
- 片元输入/输出、顶点输出支持 `layout(location=N)`，分别映射到 `TEXCOORDN` 与 `SV_TargetN`。
- 输出中不保留 GLSL 注释。

生成的 HLSL 以 Shader Model 6.0 为目标（布尔 `mix` 会用到 `select`），可直接用 `dxc` 编译：

```powershell
dxc -T vs_6_0 -E main triangle.hlsl
dxc -T ps_6_0 -E main triangle_ps.hlsl
```

## 作为 Zig 库使用

`src/root.zig` 导出模块 `processor`：

```zig
const std = @import("std");
const processor = @import("processor");

pub fn convertShader(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var diagnostics = processor.diag.Diagnostics.init(allocator);

    const hlsl = try processor.convert(allocator, source, .{ .stage = .fragment }, &diagnostics);
    for (diagnostics.items.items) |diagnostic| {
        const label = if (diagnostic.kind == .err) "error" else "warning";
        std.debug.print("{d}:{d}: {s}: {s}\n", .{
            diagnostic.line,
            diagnostic.column,
            label,
            diagnostic.message,
        });
    }
    return hlsl;
}
```

`convert` 的签名：

```zig
pub fn convert(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: options.Options,
    diagnostics: *diag.Diagnostics,
) Error![]const u8
```

- `options.Options.stage` 为 `null` 时自动推断。
- 返回的切片由传入的 allocator 持有，调用方负责释放；使用 arena 最方便。
- 错误集为 `error{InvalidShader, OutOfMemory}`。`InvalidShader` 表示已在 `diagnostics` 中记录具体错误。

## 作为 C / C++ 库使用

C ABI 与 C++17 封装的构建、链接、内存管理和完整示例见 [cpp-api.md](cpp-api.md)。

```cpp
#include <glsl2hlsl/glsl2hlsl.hpp>

glsl2hlsl::Result result = glsl2hlsl::convert(source, glsl2hlsl::Stage::Fragment);
if (result) {
    std::cout << result.output;
}
```

## 集成注意

- 常量缓冲区布局按 HLSL 规则打包，不模拟 GLSL 的 `std140`。结构体与数组作为 uniform 时，需要调用方确认 CPU 端数据布局与 HLSL 打包一致。
- 所有普通 uniform 共用一个 `b0`。如果引擎已经占用 `b0`，需要修改生成结果或后续增加寄存器配置。
- 纹理与采样器按声明顺序连续分配寄存器。若需与既有管线绑定保持一致，应调整声明顺序或手工修改寄存器。
- 顶点输入语义依赖命名约定；命名不规范时请使用 `layout(location=N)` 或手工调整生成结果。
