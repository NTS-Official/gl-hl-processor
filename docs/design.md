# 设计

## 目标

用纯 Zig 实现一个可直接阅读、可扩展的 GLSL → HLSL 源码转换器，不依赖 shaderc、glslang、SPIRV-Cross，也不经过 SPIR-V 中间表示。

第一阶段只解决“最常见的顶点/片元着色器能正确转换并通过 DXC 编译”。因此实现优先保证语义明确的子集，遇到无法可靠翻译的语法时给出诊断，而不是生成可能错误的代码。

## 总体流水线

```text
GLSL 源码
  │
  ├─ preprocess  注释剥离、CRLF 归一化、#version、对象宏、条件编译
  ├─ token       词法分析，记录 1-based 行列号
  ├─ parser      递归下降，生成 arena 上的 AST
  ├─ inferStage  根据内置变量/采样器推断阶段（可被 --stage 覆盖）
  └─ emitter     收集声明、校验、生成 IO 结构体与 HLSL 函数体
        │
        └─ HLSL 源码
```

与 naga 的相似之处在于先建立完整语法树、再做语义检查和输出；不同之处在于这里直接生成 HLSL 文本，没有中间 IR，也没有完整的类型检查器。

## 模块职责

### 预处理与词法

`src/glsl/preprocess.zig` 按行扫描，保留换行以维持行号。支持对象式宏、`#undef`、`#if` 系列、`defined()`、`#error`、`#warning`，忽略 `#extension`、`#pragma`、`#line`。`#include` 与函数式宏会直接报错。

`src/glsl/token.zig` 使用最大匹配原则，处理十进制/十六进制整数、浮点数、指数、`u` / `f` / `lf` 后缀、单行与块注释。每个 token 记录 `line`、`column`，供后续诊断使用。

### 语法树与解析

`src/glsl/ast.zig` 用 tagged union 表示表达式和语句，声明节点区分变量、函数、结构体。所有节点由 arena 分配，生命周期与一次转换相同，不需要逐个释放。

`src/glsl/parser.zig` 是手写递归下降解析器：

- 外部声明支持限定符、结构体、函数原型/定义、逗号分隔的变量声明、数组后缀与初始化表达式。
- 语句支持块、`if`、`for`、`while`、`do-while`、`switch`、`return`、`break`、`continue`、`discard`。
- 表达式使用优先级爬升处理二元运算符，赋值右结合，支持三目、成员访问、下标、函数调用与逗号表达式。
- 后缀 `++` / `--` 原样输出；前缀形式在解析时改写为 `+= 1` / `-= 1`。

解析器只做语法层面的检查（例如未知类型、重复的结构体字段），不做类型推导。

### 类型模型

`src/glsl/types.zig` 的类型是：

```zig
union(enum) {
    void_,
    scalar: Scalar,
    vector: Vector,
    matrix: Matrix,
    sampler: SamplerKind,
    array: Array,
    named: []const u8,
    unknown,
}
```

- `Scalar` 为 `bool` / `int` / `uint` / `float` / `double`。
- `Matrix` 保留 GLSL 的 `cols` × `rows`；生成 HLSL 名称时转成 `float{rows}x{cols}`。
- `SamplerKind` 记录基础标量、是否 shadow、坐标维数、是否数组、是否 buffer。
- `unknown` 用于无法静态确定的表达式；它只影响少数优化/改写判断，不会阻止代码生成。

类型推断只服务于必要场景：判断乘法是否需要改写成 `mul()`、判断构造函数如何展开、判断成员访问是 swizzle 还是结构体字段。它不是完整类型检查器。

### 生成器

`src/hlsl/emitter.zig` 分为几个阶段：

1. **collect**：收集结构体、函数、全局变量，并记录 uniform 的类别。
2. **validate**：检查当前不支持的组合，例如函数重载、采样器参数、矩阵索引、shader 内使用 stage 变量等。
3. **buildIo**：为顶点/片元输入输出分配语义，生成 `VSInput` / `VSOutput` / `PSInput` / `PSOutput`。
4. **emitStructs / emitGlobals / emitIoStructs / emitHelpers / emitFunctions / emitEntry**：按顺序输出。

`src/hlsl/code.zig` 是一个带缩进状态的字符串写入器，避免在生成器里手工拼接缩进。

## 关键取舍

### 矩阵

GLSL 与 HLSL 的矩阵在数学上都可以视为行×列，但构造参数顺序、存储布局和乘法写法不同。这里选择的策略是：

- **保持矩阵的数学含义不变**。GLSL `matCxR` 输出为 `floatRxC`。
- **常量缓冲区使用 HLSL 默认的列主序存储**，因此与 GLSL 的列主序内存布局一致，不需要在上传时转置。
- **矩阵参与乘法时改写为 `mul(a, b)`**，包括矩阵×向量、向量×矩阵、矩阵×矩阵；矩阵×标量仍然是 `*`。
- **从列向量构造矩阵**：GLSL `mat3(c0, c1, c2)` 的三个参数是列，而 HLSL `float3x3(...)` 按行接收，因此输出 `transpose(float3x3(c0, c1, c2))`。
- **从标量构造矩阵**：GLSL 参数按列主序排列，输出时重排为 HLSL 构造函数的行主序；单标量构造（如 `mat4(1.0)`）显式展开对角线。
- **矩阵索引**：GLSL 的 `m[i]` 返回列向量，HLSL 的 `m[i]` 返回行向量，语义不同，第一阶段直接报错，避免静默错误。

### uniform 与寄存器

所有非采样器 uniform 放进一个 `cbuffer Globals : register(b0)`。这样做实现简单，生成的 HLSL 也容易阅读；代价是无法保留 GLSL 的 uniform 块布局，也无法自动避开引擎已占用的寄存器。

采样器拆成两个对象：

```hlsl
Texture2D<float4> u_tex : register(t0);
SamplerState u_tex_sampler : register(s0);
```

纹理与采样器分别连续编号；buffer 采样器只生成 `Buffer`，不生成 `SamplerState`。

### 入口与语义

GLSL 的入口是 `void main()`，数据通过全局变量传递。HLSL 需要用结构体参数和返回值表达语义，因此生成器会：

- 创建 `VSInput` / `VSOutput` / `PSInput` / `PSOutput`。
- 把 GLSL 的 `in` / `out` / `varying` / `attribute` 全局变量改写成 `input.name` / `output.name`。
- 在入口开头声明 `VSOutput output;` 或 `PSOutput output;`，并把 `return;` 改写为 `return output;`。
- 为系统内置变量分配固定语义：`gl_Position` → `SV_Position`，`gl_VertexID` → `SV_VertexID`，`gl_FragCoord` → `SV_Position`，`gl_FrontFacing` → `SV_IsFrontFace`，`gl_FragDepth` → `SV_Depth`，`gl_FragColor` → `SV_Target0`。

顶点着色器强制要求写 `gl_Position`；阶段变量只允许在 `main` 中使用。这避免了辅助函数隐式依赖入口局部变量的问题。

### 诊断与容错

`src/diag.zig` 收集错误和警告。解析器遇到无法继续的错误时返回 `InvalidShader`，生成器在无法保证语义时立即失败。命令行在存在错误时不写输出文件，避免留下半成品。

### 库边界

`src/capi.zig` 把内部 Zig 接口包装成 C ABI。转换使用 arena，结束后把 HLSL 与诊断复制到库自己的分配器上，因此调用方拿到的 `glsl2hlsl_result` 不依赖转换期的临时内存。

- C ABI 使用整型状态码，不向 C 调用方传播 Zig 错误集。
- 所有 `output`、诊断数组和 `message` 由库分配，必须用 `glsl2hlsl_result_free` 释放。
- C++ 封装是头文件式的，构造 `Result` 时复制数据，并在析构 guard 中释放原始 C 结果。
- 库不依赖 libc；分配使用 Zig 的通用分配器，避免要求调用方匹配 CRT。

## 测试策略

- 单元测试覆盖词法、预处理、解析、端到端生成和 C ABI。
- `tests/shaders/` 覆盖矩阵构造、纹理采样、结构体 uniform、`switch`、传统 GLSL（`varying` / `texture2D` / `gl_FragColor`）、系统内置变量等。
- `tests/run.ps1` 批量转换，并用 DXC 以 `vs_6_0` / `ps_6_0` 编译生成结果。DXC 只验证语法与语义合法性，不验证渲染结果是否与 GLSL 一致。
- `tests/cpp/` 通过 `zig build cpp-test` 编译并运行，验证 C++ 头文件、链接、结果读取和错误处理。
- 输入 GLSL 可用 `glslangValidator` 单独校验。

## 后续计划

1. 支持 `uniform` 块（UBO）与显式 `binding` / `location`。
2. 结构体构造函数、函数重载、更多内置函数（`inverse`、`textureSize`、`texelFetch` 的多重采样版本等）。
3. 更完整的类型检查与隐式转换规则。
4. 可配置的寄存器分配、语义命名与入口名。
5. 计算/几何/曲面细分着色器。
6. 可选的注释保留与源码映射。
