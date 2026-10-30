cbuffer Globals : register(b0)
{
    float4x4 u_mvp;
    float4x4 u_model;
};

struct VSInput {
    float3 a_position : POSITION;
    float2 a_uv : TEXCOORD1;
    float3 a_normal : NORMAL;
};

struct VSOutput {
    float4 gl_position : SV_Position;
    float3 v_normal : TEXCOORD0;
    float2 v_uv : TEXCOORD1;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    output.gl_position = mul(u_mvp, float4(input.a_position, 1.0));
    output.v_normal = (mul(u_model, float4(input.a_normal, 0.0))).xyz;
    output.v_uv = input.a_uv;
    return output;
}
