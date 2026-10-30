cbuffer Globals : register(b0)
{
    float4x4 u_mvp;
};

struct VSInput {
    float3 a_position : POSITION;
};

struct VSOutput {
    float4 gl_position : SV_Position;
    float2 v_uv : TEXCOORD0;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float3x3 rotation = float3x3(0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0);
    float3x3 identity = transpose(float3x3(float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0)));
    float3 p = mul(rotation, input.a_position);
    p = mul(identity, p);
    output.gl_position = mul(u_mvp, float4(p, 1.0));
    output.v_uv = input.a_position.xy;
    return output;
}
