Texture2D<float4> u_tex : register(t0);
SamplerState u_tex_sampler : register(s0);

struct PSInput {
    float2 v_uv : TEXCOORD0;
};

struct PSOutput {
    float4 gl_frag_color : SV_Target0;
};

PSOutput main(PSInput input)
{
    PSOutput output;
    float4 color = u_tex.Sample(u_tex_sampler, input.v_uv);
    if (color.w < 0.5)
    {
        discard;
    }
    output.gl_frag_color = color;
    return output;
}
