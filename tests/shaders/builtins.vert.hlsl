cbuffer Globals : register(b0)
{
    float4x4 u_mvp;
};

struct VSInput {
    uint gl_vertex_id : SV_VertexID;
    uint gl_instance_id : SV_InstanceID;
};

struct VSOutput {
    float4 gl_position : SV_Position;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float id = float(input.gl_vertex_id);
    float instance = float(input.gl_instance_id);
    float3 p = float3(id * 0.001, instance * 0.001, 0.0);
    output.gl_position = mul(u_mvp, float4(p, 1.0));
    return output;
}
