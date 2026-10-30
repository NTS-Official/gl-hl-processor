cbuffer Globals : register(b0)
{
    float3 u_light_dir;
};

Texture2D<float4> u_albedo : register(t0);
SamplerState u_albedo_sampler : register(s0);

struct PSInput {
    float3 v_normal : TEXCOORD0;
    float2 v_uv : TEXCOORD1;
};

struct PSOutput {
    float4 frag_color : SV_Target0;
};

PSOutput main(PSInput input)
{
    PSOutput output;
    float4 albedo = u_albedo.Sample(u_albedo_sampler, input.v_uv);
    float ndotl = max(dot(normalize(input.v_normal), normalize(u_light_dir)), 0.0);
    output.frag_color = float4(albedo.xyz * ndotl, albedo.w);
    return output;
}
