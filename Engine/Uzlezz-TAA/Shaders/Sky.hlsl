#ifndef NUM_DIR_LIGHTS
#define NUM_DIR_LIGHTS 3
#endif

#ifndef NUM_POINT_LIGHTS
#define NUM_POINT_LIGHTS 0
#endif

#ifndef NUM_SPOT_LIGHTS
#define NUM_SPOT_LIGHTS 0
#endif


#include "Common.hlsl"

struct VertexIn
{
	float3 PosL : POSITION;
	float3 NormalL : NORMAL;
	float2 TexC : TEXCOORD;
};

struct VertexOut
{
	float4 PosH : SV_POSITION;
	float3 PosL : POSITION;
};

VertexOut VS(VertexIn vin)
{
	VertexOut vout;
	vout.PosL = vin.PosL;

	float4 posW = mul(float4(vin.PosL, 1.0f), gWorld);
	posW.xyz += gEyePosW;
	vout.PosH = mul(posW, gViewProj).xyww;

	return vout;
}

float4 PS(VertexOut pin) : SV_Target
{
	float3 dir = normalize(pin.PosL);
	float3 skyCube = gCubeMap.Sample(gsamLinearWrap, dir).rgb;

	float up = saturate(dir.y * 0.5f + 0.5f);
	float3 horizonColor = float3(0.45f, 0.55f, 0.75f);
	float3 zenithColor  = float3(0.05f, 0.10f, 0.20f);
	float3 gradSky = lerp(horizonColor, zenithColor, up);
	float3 skyColor = lerp(skyCube, gradSky, 0.5f);

	float3 sunDir = -normalize(gLights[0].Direction);
	float3 sunStrength = gLights[0].Strength;
	float cosTheta = dot(dir, sunDir);

	float sunDiskRadius = 0.003f;
	float sunFeather    = 0.002f;

	float sunCore = smoothstep(sunDiskRadius + sunFeather, sunDiskRadius, 1.0f - cosTheta);
	float sunGlow = smoothstep(0.03f, 0.0f, 1.0f - cosTheta);
	float sunIntensity = sunCore * 20.0f + sunGlow * 3.0f;

	float3 sunTint  = float3(1.0f, 0.95f, 0.85f);
	float3 sunColor = sunStrength * sunTint * sunIntensity;

	skyColor += sunColor;

	return float4(skyColor, 1.0f);
}
