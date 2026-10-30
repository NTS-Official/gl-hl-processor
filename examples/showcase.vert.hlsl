static const float SCALE = 2.0;

cbuffer Globals : register(b0)
{
    float4x4 u_mvp;
    float4x4 u_normal;
};

struct VSInput {
    float3 a_position : POSITION;
    float3 a_normal : NORMAL;
};

struct VSOutput {
    float4 gl_position : SV_Position;
    float3 v_normal : TEXCOORD0;
    float2 v_uv : TEXCOORD1;
};

float3 transform_normal(float3 n)
{
    return normalize((mul(u_normal, float4(n, 0.0))).xyz);
}

VSOutput main(VSInput input)
{
    VSOutput output;
    float3 p = input.a_position * SCALE;
    output.gl_position = mul(u_mvp, float4(p, 1.0));
    output.v_normal = transform_normal(input.a_normal);
    output.v_uv = float2(input.a_position.x, input.a_position.y) * 0.5 + 0.5;
    return output;
}
