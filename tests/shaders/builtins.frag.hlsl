Texture2D<float4> u_tex : register(t0);
SamplerState u_tex_sampler : register(s0);

struct PSInput {
    float4 gl_frag_coord : SV_Position;
    bool gl_front_facing : SV_IsFrontFace;
};

struct PSOutput {
    float4 frag_color : SV_Target0;
    float gl_frag_depth : SV_Depth;
};

PSOutput main(PSInput input)
{
    PSOutput output;
    float2 uv = input.gl_frag_coord.xy / float2(800.0, 600.0);
    float4 c = u_tex.Sample(u_tex_sampler, uv);
    if (!input.gl_front_facing)
    {
        c = float4(0.0, 0.0, 0.0, 0.0);
    }
    output.gl_frag_depth = input.gl_frag_coord.z;
    output.frag_color = c;
    return output;
}
