//=============================================================================
// Sky.fx by Frank Luna (C) 2011 All Rights Reserved.
//=============================================================================

// Include common HLSL code.
#include "Common.hlsl"

struct VertexIn
{
	float3 PosL    : POSITION;
	float3 NormalL : NORMAL;
	float2 TexC    : TEXCOORD;
};

struct VertexOut
{
	float4 PosH : SV_POSITION;
    float3 PosL : POSITION;
};
 
VertexOut VS(VertexIn vin)
{
	VertexOut vout;

	// Use local vertex position as cubemap lookup vector.
	vout.PosL = vin.PosL;
	
	// Transform to world space.
	float4 posW = mul(float4(vin.PosL, 1.0f), gWorld);

	// Always center sky about camera.
	posW.xyz += gEyePosW;

	// Set z = w so that z/w = 1 (i.e., skydome always on far plane).
	vout.PosH = mul(posW, gViewProj).xyww;
	
	return vout;
}

float4 PS(VertexOut pin) : SV_Target
{
	// Direction for sky lookup is the vertex local position (unit cube/sphere coords)
	float3 dir = normalize(pin.PosL);

	// Use a smaller far distance to avoid over-accumulation
	float farDist = 20000.0f; // reduced from 1e5
	float3 inscatter;
	float trans;
	Atmosphere_InscatterAndTransmittance(gEyePosW, dir, farDist, inscatter, trans);

	// Simple reinhard tonemap + slight contrast tweak
	inscatter = inscatter / (0.5f + inscatter);
	inscatter = saturate(inscatter * 1.1f);

	// Fallback cubemap (kept but not used by default)
	float4 env = gCubeMap.Sample(gsamLinearWrap, dir);

	float3 skyColor = inscatter;

	return float4(skyColor, 1.0f);
}
