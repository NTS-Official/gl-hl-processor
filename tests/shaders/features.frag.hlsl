cbuffer Globals : register(b0)
{
    float4 u_tint;
    float u_weights[4];
};

Texture2D<float4> u_tex : register(t0);
SamplerState u_tex_sampler : register(s0);

Texture2D<float4> u_tex_b : register(t1);
SamplerState u_tex_b_sampler : register(s1);

struct PSInput {
    float2 v_uv : TEXCOORD0;
    float3 v_color : TEXCOORD1;
};

struct PSOutput {
    float4 frag_color : SV_Target0;
};

float weight_sum(int count)
{
    float total = 0.0;
    for (int i = 0; i < count; i++)
    {
        total += u_weights[i];
    }
    return total;
}

PSOutput main(PSInput input)
{
    PSOutput output;
    float2 uv = input.v_uv * 2.0 - 1.0;
    float4 a = u_tex.SampleLevel(u_tex_sampler, uv, 0.0);
    float4 b = u_tex_b.Load(int3(int2(input.v_uv * 16.0), 0));
    float3 c = lerp(input.v_color, a.xyz, u_tint.w);
    float w = weight_sum(4);
    if (w > 100.0)
    {
        discard;
    }
    output.frag_color = float4(c + b.xyz, 1.0);
    return output;
}
