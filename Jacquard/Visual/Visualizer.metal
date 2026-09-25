#include <metal_stdlib>
using namespace metal;

// Ported from Assets/Jacquard/Visual/Visualizer.shader.
//
// Nothing but the colour the mesh was built with. Everything about what is drawn —
// where a column of a waveform sits, which of the two traces it belongs to, how far the
// ends of it are faded out — is decided on the CPU and arrives as vertices and vertex
// colours. The one thing added here is the aspect: the mesh is built in units of the
// half height, as under the Unity camera's orthographic size, and this is the
// projection that camera applied.

struct VisualizerVertex {
    float2 position;
    float4 color;
};

struct VisualizerUniforms {
    float aspect; // Width over height of the drawable
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut visualizerVertex(uint id [[vertex_id]],
                                  const device VisualizerVertex* vertices [[buffer(0)]],
                                  constant VisualizerUniforms& uniforms [[buffer(1)]])
{
    VisualizerVertex v = vertices[id];
    VertexOut out;
    out.position = float4(v.position.x / uniforms.aspect, v.position.y, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 visualizerFragment(VertexOut in [[stage_in]])
{
    return in.color;
}
