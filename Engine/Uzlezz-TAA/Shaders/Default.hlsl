//***************************************************************************************
// Default.hlsl
// Освещение + SSAO + атмосферный туман (экспоненциальный по высоте) + single scattering
// + sky cubemap влияет на цвет тумана + outline для черепа
//***************************************************************************************

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

//=========================== Noise (для лёгкого 3D-объёма) ===========================

float Hash31(float3 p)
{
    p = frac(p * 0.3183099 + 0.1);
    p *= 17.0;
    return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float Noise3D(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);

    float n000 = Hash31(i + float3(0,0,0));
    float n100 = Hash31(i + float3(1,0,0));
    float n010 = Hash31(i + float3(0,1,0));
    float n110 = Hash31(i + float3(1,1,0));
    float n001 = Hash31(i + float3(0,0,1));
    float n101 = Hash31(i + float3(1,0,1));
    float n011 = Hash31(i + float3(0,1,1));
    float n111 = Hash31(i + float3(1,1,1));

    float3 u = f * f * (3.0 - 2.0 * f);

    float n00 = lerp(n000, n100, u.x);
    float n10 = lerp(n010, n110, u.x);
    float n01 = lerp(n001, n101, u.x);
    float n11 = lerp(n011, n111, u.x);

    float n0 = lerp(n00, n10, u.y);
    float n1 = lerp(n01, n11, u.y);

    return lerp(n0, n1, u.z);
}

float Fbm3D(float3 p)
{
    float sum = 0.0;
    float amp = 0.5;
    float freq = 1.0;

    [unroll]
    for(int i = 0; i < 4; i++)
    {
        sum += Noise3D(p * freq) * amp;
        freq *= 2.0;
        amp  *= 0.5;
    }

    return sum;
}

//=========================== Structs ===========================

struct VertexIn
{
    float3 PosL     : POSITION;
    float3 NormalL  : NORMAL;
    float2 TexC     : TEXCOORD;
    float3 TangentU : TANGENT;
};

struct VertexOut
{
    float4 PosH        : SV_POSITION;
    float4 ShadowPosH  : POSITION0;
    float4 SsaoPosH    : POSITION1;
    float3 PosW        : POSITION2;
    float3 NormalW     : NORMAL;
    float3 TangentW    : TANGENT;
    float2 TexC        : TEXCOORD;
};

//=========================== VS обычный ===========================

VertexOut VS(VertexIn vin)
{
    VertexOut vout = (VertexOut)0;

    MaterialData matData = gMaterialData[gMaterialIndex];

    float4 posW = mul(float4(vin.PosL,1), gWorld);
    vout.PosW = posW.xyz;

    vout.NormalW  = mul(vin.NormalL,  (float3x3)gWorld);
    vout.TangentW = mul(vin.TangentU, (float3x3)gWorld);

    vout.PosH = mul(posW, gViewProj);

    vout.SsaoPosH = mul(posW, gViewProjTex);

    float4 texC = mul(float4(vin.TexC,0,1), gTexTransform);
    vout.TexC = mul(texC, matData.MatTransform).xy;

    vout.ShadowPosH = mul(posW, gShadowTransform);

    return vout;
}

//=========================== VS для outline (череп) ===========================

VertexOut VS_SkullOutline(VertexIn vin)
{
    VertexOut vout = (VertexOut)0;

    MaterialData matData = gMaterialData[gMaterialIndex];

    float4 posW = mul(float4(vin.PosL,1), gWorld);
    vout.PosW = posW.xyz;

    vout.NormalW  = mul(vin.NormalL,  (float3x3)gWorld);
    vout.TangentW = mul(vin.TangentU, (float3x3)gWorld);

    float4 texC = mul(float4(vin.TexC,0,1), gTexTransform);
    vout.TexC = mul(texC, matData.MatTransform).xy;

    vout.SsaoPosH   = mul(posW, gViewProjTex);
    vout.ShadowPosH = mul(posW, gShadowTransform);

    float3 nW = normalize(vout.NormalW);
    vout.PosW += nW * 0.05f;

    vout.PosH = mul(float4(vout.PosW,1), gViewProj);

    return vout;
}

//=========================== PS основной ===========================

float4 PS(VertexOut pin) : SV_Target
{
    // ===== материал / базовый лайт =====
    MaterialData matData = gMaterialData[gMaterialIndex];
    float4 diffuseAlbedo   = matData.DiffuseAlbedo;
    float3 fresnelR0       = matData.FresnelR0;
    float  roughness       = matData.Roughness;
    uint   diffuseMapIndex = matData.DiffuseMapIndex;
    uint   normalMapIndex  = matData.NormalMapIndex;

    diffuseAlbedo *= gTextureMaps[diffuseMapIndex].Sample(gsamAnisotropicWrap, pin.TexC);

#ifdef ALPHA_TEST
    clip(diffuseAlbedo.a - 0.1f);
#endif

    pin.NormalW = normalize(pin.NormalW);

    float4 normalMapSample = gTextureMaps[normalMapIndex].Sample(gsamAnisotropicWrap, pin.TexC);
    float3 bumpedNormalW   = NormalSampleToWorldSpace(normalMapSample.rgb, pin.NormalW, pin.TangentW);

    float3 toEyeW = normalize(gEyePosW - pin.PosW);

    // SSAO
    pin.SsaoPosH /= pin.SsaoPosH.w;
    float ambientAccess = gSsaoMap.Sample(gsamLinearClamp, pin.SsaoPosH.xy).r;

    float4 ambient = ambientAccess * gAmbientLight * diffuseAlbedo;

    float3 shadowFactor = float3(1.0f, 1.0f, 1.0f);
    shadowFactor[0] = CalcShadowFactor(pin.ShadowPosH);

    const float shininess = (1.0f - roughness) * normalMapSample.a;
    Material mat = { diffuseAlbedo, fresnelR0, shininess };

    float4 directLight = ComputeLighting(
        gLights, mat, pin.PosW, bumpedNormalW, toEyeW, shadowFactor);

    float4 litColor = ambient + directLight;

    // отражения
    float3 r = reflect(-toEyeW, bumpedNormalW);
    float4 reflectionColor = gCubeMap.Sample(gsamLinearWrap, r);
    float3 fresnelFactor   = SchlickFresnel(fresnelR0, bumpedNormalW, r);
    litColor.rgb += shininess * fresnelFactor * reflectionColor.rgb;

    litColor.rgb = saturate(litColor.rgb);

    // лёгкое доп. солнце по поверхности (чтобы grid явно ловил свет, но без дикой пересветки)
    {
        float3 sunDir   = -normalize(gLights[0].Direction);
        float  ndotl    = max(dot(bumpedNormalW, sunDir), 0.0f);
        float  sunBoost = 1.0f;

        float3 sunDiffuse = ndotl * gLights[0].Strength * diffuseAlbedo.rgb * sunBoost;
        litColor.rgb += sunDiffuse;
        litColor.rgb  = saturate(litColor.rgb);
    }

    // ===== Атмосфера: эксп. высотный туман + single scattering по формуле из лекции =====
    {
        float3 worldPos  = pin.PosW;
        float3 cameraPos = gEyePosW;
        float3 viewVec   = worldPos - cameraPos;
        float  dist      = length(viewVec);

        if (dist > 1e-3f)
        {
            float3 viewDir = viewVec / dist;

            float baseDensity    = max(gAtmosphereGlobalDensity, 0.0f);
            float heightFalloff  = max(gAtmosphereHeightFalloff, 0.0f);
            float cleanliness    = saturate(gAtmosphereCleanliness);
            float fogIntensity   = max(gAtmosphereIntensity, 0.0f);

            float3 sunDir   = -normalize(gLights[0].Direction);
            float3 sunColor = gLights[0].Strength;

            // --- интеграл плотности вдоль луча с экспоненциальной высотной зависимостью ---
            float  h0 = max(cameraPos.y, 0.0f);
            float  vy = viewDir.y;
            float  opticalDepth = 0.0f;

            if (heightFalloff > 1e-4f)
            {
                float H      = heightFalloff;
                float expH0  = exp(-H * h0);
                float hEnd   = max(h0 + vy * dist, 0.0f);
                float expH1  = exp(-H * hEnd);

                if (abs(vy) > 1e-3f)
                {
                    float integral = (expH0 - expH1) / (H * vy);
                    opticalDepth   = baseDensity * max(integral, 0.0f);
                }
                else
                {
                    float densityAtCam = baseDensity * exp(-H * h0);
                    opticalDepth       = densityAtCam * dist;
                }
            }
            else
            {
                // почти постоянная плотность
                float densityAtCam = baseDensity;
                opticalDepth       = densityAtCam * dist;
            }

            // немного 3D-объёма через шум — но мягко, без "дымовых" пятен
            {
                float3 noisePos = worldPos * 0.15f;
                noisePos.y += gTotalTime * 0.08f;
                noisePos.x += gTotalTime * 0.03f;

                float noise = Fbm3D(noisePos);
                noise = saturate(noise * 1.2f - 0.2f);

                float groundBoost = saturate(1.0f - (worldPos.y + 5.0f) / 40.0f);
                noise = saturate(noise + groundBoost * 0.3f);

                opticalDepth *= lerp(0.8f, 1.25f, noise);
            }

            // закон Бугера–Ламберта–Бера: F_t(s) = exp(-τ)
            float transmittance = exp(-opticalDepth);
            transmittance       = saturate(transmittance);

            // === single scattering: смесь Rayleigh + Mie, цвет из sky cubemap ===

            float mu = dot(-viewDir, sunDir); // угол между взглядом и солнцем

            // Mie: Henyey–Greenstein-подобная фазовая функция
            const float gMie = 0.8f;
            float g2    = gMie * gMie;
            float denom = pow(1.0f + g2 - 2.0f * gMie * mu, 1.5f);
            float phaseMie = (1.0f - g2) / max(denom, 1e-3f);
            phaseMie *= 0.25f;

            // Rayleigh: ~ (1 + μ²)
            float phaseRayleigh = 0.1f * (1.0f + mu * mu);

            // "чистота" атмосферы: чистый → больше Rayleigh, грязный → больше Mie
            float mieWeight = saturate(1.0f - cleanliness);
            float rayWeight = cleanliness;

            // берём цвет из sky cubemap, чтобы небо реально отражалось в тумане
            float3 skyFromView = gCubeMap.Sample(gsamLinearWrap, viewDir).rgb;
            float3 skyFromSun  = gCubeMap.Sample(gsamLinearWrap, sunDir).rgb;

            float3 rayleighColor = skyFromView;                  // голубоватый от неба
            float3 mieColor      = lerp(sunColor, skyFromSun, 0.5f); // мутно-солнечный

            float3 inScatRayleigh = rayleighColor * rayWeight * phaseRayleigh;
            float3 inScatMie      = mieColor      * mieWeight * phaseMie;

            float3 inScatteringColor = (inScatRayleigh + inScatMie) * fogIntensity;

            // формула из лекции для однородной среды:
            // L = L_surface * F_t(s) + L_vol * (1 - F_t(s))
            float oneMinusT = 1.0f - transmittance;

            float3 fogColor = inScatteringColor * oneMinusT;

            // чуть затемняем самые плотные места, чтобы не было мыльной засветки
            fogColor = saturate(fogColor);

            litColor.rgb = litColor.rgb * transmittance + fogColor;
            litColor.rgb = saturate(litColor.rgb);
        }
    }

    litColor.a = diffuseAlbedo.a;
    return litColor;
}

//=========================== PS Outline ===========================

float4 PS_SkullOutline(VertexOut pin) : SV_Target
{
    // чистый красный контур (можешь подправить цвет/альфу)
    return float4(1.0f, 0.0f, 0.0f, 1.0f);
}
