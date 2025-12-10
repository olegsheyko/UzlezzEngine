// VelocityPass.hlsl
#include "LightingUtil.hlsl"

cbuffer ObjectConstants : register(b0)
{
    float4x4 gWorld;
    float4x4 gInvWorld;
    float4x4 gTexTransform;
};

cbuffer PassConstants : register(b1)
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

struct VSInput
{
    float3 PosL    : POSITION;
    float3 Normal  : NORMAL;
    float2 TexC    : TEXCOORD;
    float3 Tangent : TANGENT;
};

struct VSOutput
{
    float4 PosH        : SV_POSITION;
    float4 PrevPosH    : PREV_POS;
};

VSOutput VS(VSInput vin)
{
    VSOutput vout;

    float4 posW = mul(float4(vin.PosL, 1.0f), gWorld);

    float4 currClip = mul(posW, gViewProj);
    float4 prevClip = mul(posW, gPrevViewProj);

    vout.PosH     = currClip;
    vout.PrevPosH = prevClip;
    return vout;
}

float2 NDC(float4 clip)
{
    float2 ndc = clip.xy / max(clip.w, 1e-4f);
    return ndc;
}

float4 PS(VSOutput pin) : SV_TARGET
{
    float2 currNdc = NDC(pin.PosH);
    float2 prevNdc = NDC(pin.PrevPosH);

    float2 vel = currNdc - prevNdc;

    return float4(vel, 0.0f, 1.0f);
}

