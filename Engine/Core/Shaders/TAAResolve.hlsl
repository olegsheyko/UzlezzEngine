// TAAResolve.hlsl
// Простой resolve‑пас для TAA: реконсрукция цвета по текущему кадру,
// истории и вектору скорости.

#include "LightingUtil.hlsl"

cbuffer PassConstants : register(b0)
{
    float4x4 gView;
    float4x4 gInvView;
    float4x4 gProj;
    float4x4 gInvProj;
    float4x4 gViewProj;
    float4x4 gInvViewProj;
    float4x4 gPrevView;
    float4x4 gPrevProj;
    float4x4 gPrevViewProj;
    float3   gEyePosW;
    float    pad0;
    float2   gRenderTargetSize;
    float2   gInvRenderTargetSize;
    float    gNearZ;
    float    gFarZ;
    float    gTotalTime;
    float    gDeltaTime;
    float2   gJitter;
    float2   gPrevJitter;
    float    gTaaFeedbackMin;
    float    gTaaFeedbackMax;
    float    gTaaSharpness;
    float    gTaaMotionBlend;
    int      gTaaEnabled;
    float3   pad1;
};

Texture2D gCurrColor    : register(t0); // текущий HDR‑кадр
Texture2D gHistoryColor : register(t1); // история
Texture2D gVelocityTex  : register(t2); // вектора скорости в NDC
SamplerState gLinearClamp : register(s0);

struct VSQuadOut
{
    float4 PosH : SV_POSITION;
    float2 TexC : TEXCOORD0;
};

// Полноэкранный треугольник по SV_VertexID.
VSQuadOut VS_QUAD(uint vid : SV_VertexID)
{
    VSQuadOut v;

    const float2 pos[3] = {
        float2(-1.0f, -1.0f),
        float2(-1.0f,  3.0f),
        float2( 3.0f, -1.0f)
    };

    const float2 uv[3] = {
        float2(0.0f, 1.0f),
        float2(0.0f, -1.0f),
        float2(2.0f, 1.0f)
    };

    v.PosH = float4(pos[vid], 0.0f, 1.0f);
    v.TexC = uv[vid];
    return v;
}

float4 PS(VSQuadOut pin) : SV_TARGET
{
    float2 uv = pin.TexC;

    float4 curr = gCurrColor.Sample(gLinearClamp, uv);

    // Если TAA выключен — сразу отдаём текущий кадр.
    if (gTaaEnabled == 0)
        return curr;

    // Velocity хранится в NDC‑пространстве (см. VelocityPass.hlsl).
    float2 vel = gVelocityTex.Sample(gLinearClamp, uv).xy;

    // Проецируем координату истории назад по движению.
    float2 historyUv = uv - vel * 0.5f;
    historyUv = saturate(historyUv);

    float4 hist = gHistoryColor.Sample(gLinearClamp, historyUv);

    // Простая схема feedback‑фактора, как в статье:
    float feedback = lerp(gTaaFeedbackMin, gTaaFeedbackMax, gTaaMotionBlend);

    float4 result = lerp(curr, hist, feedback);

    return result;
}
