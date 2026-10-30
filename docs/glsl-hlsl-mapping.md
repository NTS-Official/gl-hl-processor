# GLSL 到 HLSL 的映射规则

本文档描述 `glsl2hlsl` 当前（第一阶段）具体做了哪些改写。未列出的语法视为不支持。

## 类型

| GLSL | HLSL |
| --- | --- |
| `void` | `void` |
| `float` / `int` / `uint` / `bool` / `double` | 同名 |
| `vec2/3/4` | `float2/3/4` |
| `ivec2/3/4` | `int2/3/4` |
| `uvec2/3/4` | `uint2/3/4` |
| `bvec2/3/4` | `bool2/3/4` |
| `dvec2/3/4` | `double2/3/4` |
| `matN` | `floatNxN` |
| `matCxR` | `floatRxC` |
| `sampler2D` 等 | `Texture2D<float4>` + `SamplerState` |
| `isampler2D` / `usampler2D` | `Texture2D<int4>` / `Texture2D<uint4>` |
| 结构体 | 原样输出为 `struct` |
| `T[len]` | `T name[len]` |

`matCxR` 的列数和行数在 HLSL 中顺序相反：GLSL 的 `mat3x4` 有 3 列 4 行，对应 `float4x3`。类型名按 HLSL 的“行 x 列”规则重新排列。

`lowp` / `mediump` / `highp` 被忽略。`layout(location = N)` 用于顶点输入语义、顶点输出与片元输入/输出的 `TEXCOORDN` / `SV_TargetN` 编号；其余 layout 限定符被忽略。

## 存储限定符

| GLSL | HLSL 输出 |
| --- | --- |
| `uniform`（非采样器） | `cbuffer Globals : register(b0)` 中的字段 |
| `uniform sampler...` | `Texture2D<...> name : register(tN);` 加 `SamplerState name_sampler : register(sN);` |
| `const` 全局 | `static const` |
| `in` / `attribute`（main 中） | 输入结构体字段 |
| `out` / `varying`（main 中） | 输出结构体字段，或片元输出 `SV_TargetN` |
| 局部变量 | 原样输出 |

所有非采样器 uniform 共用一个 `b0` 常量缓冲。采样器与常量缓冲寄存器分别从 `t0`、`s0` 开始顺序编号。

## 入口与内置变量

入口函数统一命名为 `main`：

- 顶点着色器：`VSOutput main(VSInput input)`，返回值带 `SV_Position`。
- 片元着色器：`PSOutput main(PSInput input)`；没有输出时返回 `void`。
- 没有输入时省略参数。

| GLSL | HLSL |
| --- | --- |
| `gl_Position` | `VSOutput.gl_position : SV_Position` |
| `gl_VertexID` | `VSInput.gl_vertex_id : SV_VertexID`（`uint`） |
| `gl_InstanceID` | `VSInput.gl_instance_id : SV_InstanceID`（`uint`） |
| `gl_FragCoord` | `PSInput.gl_frag_coord : SV_Position`（`float4`） |
| `gl_FrontFacing` | `PSInput.gl_front_facing : SV_IsFrontFace`（`bool`） |
| `gl_FragColor` | `PSOutput.gl_frag_color : SV_Target0`（旧式写法） |
| `gl_FragDepth` | `PSOutput.gl_frag_depth : SV_Depth` |
| `discard` | `discard` |

`gl_PointSize`、`gl_ClipDistance`、`gl_PrimitiveID` 等尚未支持。

顶点输入语义按名称推断：`position` → `POSITION`，`normal` → `NORMAL`，`tangent` → `TANGENT`，`bitangent`/`binormal` → `BINORMAL`，`color`/`colour` → `COLOR`，`weight` → `BLENDWEIGHT`，`joint`/`index` → `BLENDINDICES`。名称无法识别时使用 `layout(location = N)` 对应的 `TEXCOORDN`，没有 layout 时按声明顺序分配 `TEXCOORDn`。

顶点输出与片元输入一律使用递增的 `TEXCOORDn`。片元输出使用 `SV_Targetn`。片元输入上的 `flat` 输出为 `nointerpolation`，`noperspective` 输出为 `noperspective`。

## 运算符

- 任一操作数为矩阵、且不是“矩阵 × 标量”时，按 GLSL 的线性代数语义改写为 `mul(a, b)`；向量 × 向量仍是逐分量乘法，保持 `*`。
- 矩阵与矩阵的 `*=` 改写为 `m = mul(m, n)`；其余复合赋值保持原样。
- 向量比较函数 `lessThan`、`greaterThan`、`equal` 等改为运算符 `<`、`>`、`==`。
- `matrixCompMult(a, b)` 改为 `a * b`（HLSL 的矩阵 `*` 是逐分量乘法）。
- `%` 仅在整数上使用，HLSL 语义一致。

## 构造函数

- `vecN(scalar)` 展开为 N 个相同分量，例如 `float3(1.0)` → `float3(1.0, 1.0, 1.0)`。
- `vecN(较短向量)` 补齐缺少的分量，第四分量补 1，其余补 0：`vec4(v3)` → `float4(v3, 1)`，`vec3(v2)` → `float3(v2, 0)`。
- `vecN(较长向量)` 截断为前缀，例如 `vec3(v4)` → `(v4).xyz`。
- 多参数构造要求分量总数恰好等于目标长度。
- `matN(scalar)` 生成对角矩阵。
- `matN(标量列表)` 按列优先顺序读取参数，输出时重排为 HLSL 的行优先顺序。
- `matN(列向量...)` 输出为 `transpose(floatCxR(v0, v1, ...))`。
- `matN(matM)` 仅在目标维度不大于源维度时使用 HLSL 强制转换（取左上角子矩阵）；扩大维度会报错。

结构体构造函数、矩阵动态索引均不支持。

## 内置函数

直接改名或改写：

| GLSL | HLSL |
| --- | --- |
| `mix`（第三个参数为浮点） | `lerp` |
| `mix`（第三个参数为布尔） | `select(选择, y, x)` |
| `fract` | `frac` |
| `inversesqrt` | `rsqrt` |
| `dFdx` / `dFdy` | `ddx` / `ddy` |
| `fma` | `mad` |
| `roundEven` | `round` |
| `atan(y, x)` | `atan2(y, x)` |
| `mod` | 生成的 `glsl_mod` 重载 |
| `not` | `!` |

名称相同的数学函数直接透传：`sin`、`cos`、`tan`、`asin`、`acos`、`atan`（单参数）、`sinh`、`cosh`、`tanh`、`asinh`、`acosh`、`atanh`、`pow`、`exp`、`log`、`exp2`、`log2`、`log10`、`sqrt`、`abs`、`sign`、`floor`、`ceil`、`round`、`trunc`、`radians`、`degrees`、`clamp`、`min`、`max`、`step`、`smoothstep`、`length`、`distance`、`dot`、`cross`、`normalize`、`faceforward`、`reflect`、`refract`、`any`、`all`、`isnan`、`isinf`、`fwidth`、`transpose`、`determinant`。

`mod` 会按需生成 `glsl_mod` 重载，覆盖 `float`/`float2`/`float3`/`float4` 以及向量与标量的组合。

## 纹理采样

| GLSL | HLSL |
| --- | --- |
| `texture(s, uv)` | `s.Sample(s_sampler, uv)` |
| `textureLod(s, uv, lod)` | `s.SampleLevel(s_sampler, uv, lod)` |
| `textureGrad(s, uv, dx, dy)` | `s.SampleGrad(s_sampler, uv, dx, dy)` |
| `texelFetch(s, coord, lod)` | `s.Load(int3(coord, lod))` |
| `texelFetch(buffer, coord)` | `buffer.Load(coord)` |

顶点着色器中的 `texture()` 会改写为 `SampleLevel(..., 0.0)`，因为 `Sample` 只在像素阶段可用。`texture2D`、`texture2DLod`、`textureCube` 等旧式名称按同一规则处理。

以下情况会报错：采样器作为函数参数、采样器数组、阴影采样器、对 buffer 采样器调用 `texture()`、在顶点着色器中使用 `textureGrad`。

## 流程控制

`if`、`for`、`while`、`do-while`、`switch/case/default`、`break`、`continue`、`return`、`discard` 均直接输出。`for` 的初始化可以是声明或表达式。后缀 `++` / `--` 原样输出，前缀形式改写为 `+= 1` / `-= 1`。

## 不支持的特性

- 几何、细分、计算着色器。
- uniform 块（UBO）、接口块、`layout(std140)` 显式布局。
- 函数重载、结构体构造函数。
- 结构体或数组作为着色器输入输出。
- 矩阵动态索引、扩大维度的矩阵构造。
- 纹理 offset/bias/proj/gather、`textureSize`、`inverse`。
- 图像与原子操作（`image*`、`atomic*`）。
- 预处理器的 `#include` 与函数式宏。
- uniform 初值（`uniform float x = 1.0;`）。
- 在 `main` 之外访问 stage 内置变量或 stage 输入输出。
