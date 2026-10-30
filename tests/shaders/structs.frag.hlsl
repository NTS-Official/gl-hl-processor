struct Material {
    float3 albedo;
    float roughness;
};

cbuffer Globals : register(b0)
{
    Material u_material;
    float4 u_tint;
    int u_mode;
};

struct PSInput {
    float2 v_uv : TEXCOORD0;
};

struct PSOutput {
    float4 frag_color : SV_Target0;
};

PSOutput main(PSInput input)
{
    PSOutput output;
    float3 color = u_material.albedo * u_tint.xyz;
    switch (u_mode)
    {
        case 0:
            color = u_material.albedo;
            break;
        case 1:
            color = u_tint.xyz;
            break;
        default:
            color = float3(1.0, 1.0, 1.0);
            break;
    }
    output.frag_color = float4(color, 1.0);
    return output;
}
