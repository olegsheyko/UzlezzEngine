//***************************************************************************************
// Common.hlsl by Frank Luna (C) 2015 All Rights Reserved.
//***************************************************************************************

// Defaults for number of lights.
#ifndef NUM_DIR_LIGHTS
    #define NUM_DIR_LIGHTS 3
#endif

#ifndef NUM_POINT_LIGHTS
    #define NUM_POINT_LIGHTS 0
#endif

#ifndef NUM_SPOT_LIGHTS
    #define NUM_SPOT_LIGHTS 0
#endif

// Include structures and functions for lighting.
#include "LightingUtil.hlsl"

struct MaterialData
{
	float4   DiffuseAlbedo;
	float3   FresnelR0;
	float    Roughness;
	float4x4 MatTransform;
	uint     DiffuseMapIndex;
	uint     NormalMapIndex;
	uint     MatPad1;
	uint     MatPad2;
};

TextureCube gCubeMap : register(t0);
Texture2D gShadowMap : register(t1);
Texture2D gSsaoMap   : register(t2);

// An array of textures, which is only supported in shader model 5.1+.  Unlike Texture2DArray, the textures
// in this array can be different sizes and formats, making it more flexible than texture arrays.
Texture2D gTextureMaps[10] : register(t3);

// Put in space1, so the texture array does not overlap with these resources.  
// The texture array will occupy registers t0, t1, ..., t3 in space0. 
StructuredBuffer<MaterialData> gMaterialData : register(t0, space1);


SamplerState gsamPointWrap        : register(s0);
SamplerState gsamPointClamp       : register(s1);
SamplerState gsamLinearWrap       : register(s2);
SamplerState gsamLinearClamp      : register(s3);
SamplerState gsamAnisotropicWrap  : register(s4);
SamplerState gsamAnisotropicClamp : register(s5);
SamplerComparisonState gsamShadow : register(s6);

// Constant data that varies per frame.
cbuffer cbPerObject : register(b0)
{
    float4x4 gWorld;
	float4x4 gTexTransform;
	uint gMaterialIndex;
	uint gObjPad0;
	uint gObjPad1;
	uint gObjPad2;
};

// Constant data that varies per material.
cbuffer cbPass : register(b1)
{
    float4x4 gView;
    float4x4 gInvView;
    float4x4 gProj;
    float4x4 gInvProj;
    float4x4 gViewProj;
    float4x4 gInvViewProj;
    float4x4 gViewProjTex;
    float4x4 gShadowTransform;
    float3 gEyePosW;
    float cbPerObjectPad1;
    float2 gRenderTargetSize;
    float2 gInvRenderTargetSize;
    float gNearZ;
    float gFarZ;
    float gTotalTime;
    float gDeltaTime;
    float4 gAmbientLight;

    // Indices [0, NUM_DIR_LIGHTS) are directional lights;
    // indices [NUM_DIR_LIGHTS, NUM_DIR_LIGHTS+NUM_POINT_LIGHTS) are point lights;
    // indices [NUM_DIR_LIGHTS+NUM_POINT_LIGHTS, NUM_DIR_LIGHTS+NUM_POINT_LIGHT+NUM_SPOT_LIGHTS)
    // are spot lights for a maximum of MaxLights per object.
    Light gLights[MaxLights];

    // --- Atmosphere parameters (added) ---
    float3 gSunDirection;       // normalized sun dir (towards light)
    float  gSunIntensity;       // scalar intensity of sun

    float3 gBetaRayleigh;       // Rayleigh scattering coefficient (RGB)
    float  gBetaMie;            // Mie scattering coefficient (scalar)

    float  gMieG;               // Mie phase function asymmetry parameter (g)
    float  gAtmosphereScaleHeight; // scale height of atmosphere density (meters or scene units)
    float  gExposure;           // exposure multiplier for final inscatter
    float  gAtmospherePad0;     // pad to 16 bytes

    float  gAtmosphereDebugMode; // 0=normal,1=show inscatter,2=show transmittance
};

//---------------------------------------------------------------------------------------
// Transforms a normal map sample to world space.
//---------------------------------------------------------------------------------------
float3 NormalSampleToWorldSpace(float3 normalMapSample, float3 unitNormalW, float3 tangentW)
{
	// Uncompress each component from [0,1] to [-1,1].
	float3 normalT = 2.0f*normalMapSample - 1.0f;

	// Build orthonormal basis.
	float3 N = unitNormalW;
	float3 T = normalize(tangentW - dot(tangentW, N)*N);
	float3 B = cross(N, T);

	float3x3 TBN = float3x3(T, B, N);

	// Transform from tangent space to world space.
	float3 bumpedNormalW = mul(normalT, TBN);

	return bumpedNormalW;
}

//---------------------------------------------------------------------------------------
// PCF for shadow mapping.
//---------------------------------------------------------------------------------------
//#define SMAP_SIZE = (2048.0f)
//#define SMAP_DX = (1.0f / SMAP_SIZE)
float CalcShadowFactor(float4 shadowPosH)
{
    // Complete projection by doing division by w.
    shadowPosH.xyz /= shadowPosH.w;

    // Depth in NDC space.
    float depth = shadowPosH.z;

    uint width, height, numMips;
    gShadowMap.GetDimensions(0, width, height, numMips);

    // Texel size.
    float dx = 1.0f / (float)width;

    float percentLit = 0.0f;
    const float2 offsets[9] =
    {
        float2(-dx,  -dx), float2(0.0f,  -dx), float2(dx,  -dx),
        float2(-dx, 0.0f), float2(0.0f, 0.0f), float2(dx, 0.0f),
        float2(-dx,  +dx), float2(0.0f,  +dx), float2(dx,  +dx)
    };

    [unroll]
    for(int i = 0; i < 9; ++i)
    {
        percentLit += gShadowMap.SampleCmpLevelZero(gsamShadow,
            shadowPosH.xy + offsets[i], depth).r;
    }
    
    return percentLit / 9.0f;
}

// Physical / empirical constants
static const float PI = 3.14159265359f;

// Rayleigh phase function (symmetric)
float RayleighPhase(float cosTheta)
{
    return (3.0f / (16.0f * PI)) * (1.0f + cosTheta * cosTheta);
}

// Henyey-Greenstein phase function for Mie (forward scattering dominated)
float MiePhase(float cosTheta, float g)
{
    float g2 = g * g;
    float denom = pow(1.0f + g2 - 2.0f * g * cosTheta, 1.5f);
    return (1.0f - g2) / (4.0f * PI * denom + 1e-6f);
}

// Exponential height density: density = exp(-(height)/scaleHeight)
float HeightDensity(float height, float scaleHeight)
{
    // height expected in same units as scaleHeight. clamp to non-negative.
    return exp(-max(0.0f, height) / max(1e-6f, scaleHeight));
}

// Beer-Lambert transmittance for per-channel sigma and distance
float3 BeerLambert(float3 sigma, float dist)
{
    return exp(-sigma * dist);
}

// Approximate single-scattering inscattering + transmittance between startPos and a point at distance 'dist' along 'dir'.
// This is a real-time approximation (no full ray-marching): we evaluate density at the start point and use an
// analytic-like expression T = exp(-beta * d) and inscatter ~= SunI * Phase * beta * (1 - exp(-beta * d)) / beta.
// Arguments:
//   startPos - world position where ray starts (camera)
//   dir - normalized ray direction (from camera into scene)
//   dist - distance along ray from startPos to the surface point (for sky use a large value)
// Outputs:
//   outInscatter - RGB inscattered radiance added along the ray reaching the camera
//   outTransmittance - average transmittance (scalar) applied to surface color
void Atmosphere_InscatterAndTransmittance(float3 startPos, float3 dir, float dist, out float3 outInscatter, out float outTransmittance)
{
    // Clamp distance to avoid runaway accumulation for very long rays (sky).
    dist = min(dist, 4000.0f);

    // Estimate density at camera height and at far point along the ray, then average.
    float h0 = startPos.y; // camera height
    float h1 = startPos.y + dir.y * dist; // height at far point along the ray

    float dens0 = HeightDensity(h0, gAtmosphereScaleHeight);
    float dens1 = HeightDensity(h1, gAtmosphereScaleHeight);

    // average density along the ray (simple approximation)
    float avgDensity = max(0.0f, 0.5f * (dens0 + dens1));

    // Local scattering coefficients (per-channel) using average density
    float3 betaR = gBetaRayleigh * avgDensity; // Rayleigh per channel
    float3 betaM = float3(gBetaMie, gBetaMie, gBetaMie) * avgDensity; // Mie treated as gray

    // Total extinction coefficient (scattering + absorption).
    float3 betaTot = betaR + betaM;

    // Transmittance from camera to surface point (per channel)
    float3 trans = BeerLambert(betaTot, dist);

    // Phase terms (angle between view direction and sun direction)
    float cosThetaSun = dot(dir, -normalize(gSunDirection)); // dir points from camera; sun direction points toward light
    float pr = RayleighPhase(cosThetaSun);
    float pm = MiePhase(cosThetaSun, gMieG);

    // In-scattered radiance approx: per-channel
    // L = SunI * (pr * betaR + pm * betaM) * (1 - exp(-betaTot * dist)) / (betaTot)
    float3 oneMinusTrans = 1.0f - trans;
    float3 rawInscatter = gSunIntensity * (pr * betaR + pm * betaM) * (oneMinusTrans / (betaTot + 1e-6f));

    // Apply exposure
    float3 inscatter = rawInscatter * gExposure;

    // Simple tone-mapping (Reinhard) to avoid blowout: L = L / (1 + L)
    inscatter = inscatter / (1.0f + inscatter);

    // Clamp small/large values
    inscatter = saturate(inscatter);

    outInscatter = inscatter;

    // Return scalar transmittance (average across RGB) to modulate surface color
    outTransmittance = saturate((trans.x + trans.y + trans.z) / 3.0f);
}
// End of modified atmosphere helpers
