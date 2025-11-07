cbuffer cbPerObject : register(b0)
{
    float4x4 gWorld;
    float4x4 gInvWorld;
    float4x4 gTexTransform;
};

cbuffer cbPass : register(b1)
{
    float4x4 gView;
    float4x4 gInvView;
    float4x4 gProj;
    float4x4 gInvProj;
    float4x4 gViewProj;
    float4x4 gInvViewProj;
    float3 gEyePosW;
    float cbPerObjectPad1;
    float2 gRenderTargetSize;
    float2 gInvRenderTargetSize;
    float gNearZ;
    float gFarZ;
    float gTotalTime;
    float gDeltaTime;
};

cbuffer cbMaterial : register(b2)
{
    float4 gDiffuseAlbedo;
    float3 gFresnelR0;
    float gRoughness;
    float4x4 gMatTransform;
};
cbuffer cbTerrainTile : register(b3) // b3 - регистр для буфера тайла
{
    float3 gTilePosition;
    float gTileSize;
    float mapSize;
    float heightScale;
    float showborders;   // >0.5 включено
    float debugMode;     // >0.5 включен режим отладки
    float renderHMAP;    // >0.5 вывод карты высот вместо альбедо

};
// Texture resources
Texture2D gHeightMap : register(t0); // Карта высот
Texture2D gDiffuseMap : register(t1); // Диффузная текстура
Texture2D gNormalMap : register(t2); // Карта нормалей

SamplerState gSamPointWrap : register(s0);
SamplerState gSamPointClamp : register(s1);
SamplerState gSamLinearWrap : register(s2);
SamplerState gSamLinearClamp : register(s3);
SamplerState gSamAnisotropicWrap : register(s4);
SamplerState gSamAnisotropicClamp : register(s5);

struct VertexIn
{
    float3 PosL : POSITION;
    float3 NormalL : NORMAL;
    float2 TexC : TEXCOORD;
    float3 TangentU : TANGENT;
};

struct VertexOut
{
    float4 PosH : SV_POSITION;   // Позиция в клиповом пространстве
    float3 PosW : TEXCOORD3;     // Позиция в мировом пространстве
    float3 NormalW : TEXCOORD4;  // Нормаль в мировом пространстве
    float3 TangentW : TEXCOORD5; // Тангенс в мировом пространстве
    float2 TexC : TEXCOORD0;     // Основные UV (с учётом тайла)
    float2 TexCl : TEXCOORD1;    // Локальные UV внутри тайла (для границ)
    float height : TEXCOORD7;    // Высота из heightmap
};

struct PixelOut
{
    float4 Albedo : SV_Target0; // Диффузный цвет
    float4 Normal : SV_Target1; // Нормали в мировом пространстве
    float4 Position : SV_Target2; // Позиция в мировом пространстве
};


VertexOut VS(VertexIn vin)
{
    VertexOut vout = (VertexOut) 0.0f;
    
    // Вычисляем текстурные координаты
    float4 texC = mul(float4(vin.TexC, 0.0f, 1.0f), gTexTransform);
    vout.TexC = mul(texC, gMatTransform).xy;
    float coeff = gTileSize / mapSize;
    vout.TexC *= coeff;
    vout.TexC += gTilePosition.xz / mapSize;
    vout.TexCl = vin.TexC;
    
    //const float terrainScale = 0.01;
    //float height = FBM_Noise(vout.TexC * 8.0 * terrainScale);
    
    
    
    
    // Семплируем высоту из heightmap
    float height = saturate(gHeightMap.SampleLevel(gSamLinearClamp, vout.TexC, 0).r);
    vout.height = height;
    
    // Применяем высоту к Y координате
    float3 posL = vin.PosL;
    posL.y = posL.y + height * heightScale;
    
    // Трансформируем в мировые координаты
    float4 posW = mul(float4(posL, 1.0f), gWorld);
    vout.PosW = posW.xyz;
    
    // ИСПРАВЛЕННОЕ вычисление нормали
    float2 texelSize = float2(1.0f / mapSize, 1.0f / mapSize);
    
    // Семплируем высоты соседних точек
    float hL = gHeightMap.SampleLevel(gSamLinearClamp, vout.TexC + float2(-texelSize.x, 0.0f), 0).r;
    float hR = gHeightMap.SampleLevel(gSamLinearClamp, vout.TexC + float2(texelSize.x, 0.0f), 0).r;
    float hD = gHeightMap.SampleLevel(gSamLinearClamp, vout.TexC + float2(0.0f, -texelSize.y), 0).r;
    float hU = gHeightMap.SampleLevel(gSamLinearClamp, vout.TexC + float2(0.0f, texelSize.y), 0).r;
    
    // Вычисляем градиенты
    float dX = (hR - hL) * heightScale ; // градиент по X
    float dZ = (hU - hD) * heightScale ; // градиент по Z
    
    // Создаем нормаль напрямую из градиентов
    // Формула: normal = normalize((-dX, 1, -dZ))
    float3 normal = normalize(float3(-dX, 1.0f, -dZ));
    
    // Создаем тангент
    float3 tangent = normalize(float3(1.0f, dX, 0.0f));
    
    // Трансформируем в мировое пространство
    vout.NormalW = normalize(mul(normal, (float3x3) gWorld));
    vout.TangentW = normalize(mul(tangent, (float3x3) gWorld));
    
    // Трансформируем в clip space
    vout.PosH = mul(posW, gViewProj);
    
    return vout;
}
float3 NormalSampleToWorldSpace(float3 normalMapSample, float3 unitNormalW, float3 tangentW)
{
    // Распаковываем нормаль из [0,1] в [-1,1]
    float3 normalT = 2.0f * normalMapSample - 1.0f;
    
    // Строим TBN матрицу
    float3 N = unitNormalW;
    float3 T = normalize(tangentW - dot(tangentW, N) * N);
    float3 B = cross(N, T);
    
    float3x3 TBN = float3x3(T, B, N);
    
    // Трансформируем нормаль в мировое пространство
    float3 bumpedNormalW = mul(normalT, TBN);
    
    return bumpedNormalW;
}

PixelOut PS(VertexOut pin)
{
    PixelOut pout;
    
    // Семплируем диффузную текстуру
    float4 diffuseAlbedo = gDiffuseMap.Sample(gSamAnisotropicWrap, pin.TexC);
    
    // Применяем материальный цвет
    diffuseAlbedo *= gDiffuseAlbedo;
    
    // debug
    
    if (debugMode > 0.5f)
    {
        if (abs(gTileSize - mapSize) < 0.001f)
            diffuseAlbedo = float4(0.5f, 0.0f, 0.0f, 1.0f);
        else if (abs(gTileSize - mapSize / 2.0f) < 0.001f)
            diffuseAlbedo = float4(0.8f, 0.3f, 0.0f, 1.0f);
        else if (abs(gTileSize - mapSize / 4.0f) < 0.001f)
            diffuseAlbedo = float4(1.0f, 0.7f, 0.0f, 1.0f);
        else if (abs(gTileSize - mapSize / 8.0f) < 0.001f)
            diffuseAlbedo = float4(0.f, 0.3f, 0.1f, 1.0f);
        else if (abs(gTileSize - mapSize / 16.0f) < 0.001f)
            diffuseAlbedo = float4(0.1f, 0.5f, 0.1f, 1.0f);
        else if (abs(gTileSize - mapSize / 32.0f) < 0.001f)
            diffuseAlbedo = float4(0.0f, 1.0f, 0.3f, 1.0f);
        else if (abs(gTileSize - mapSize / 64.0f) < 0.001f)
            diffuseAlbedo = float4(0.0f, 1.0f, 1.0f, 1.0f);
    }

    if (showborders > 0.5f)
    {
        float2 uv = pin.TexCl;
        if (uv.x < 0.005 || uv.x > 0.995 || uv.y < 0.005 || uv.y > 0.995)
            diffuseAlbedo = float4(0, 0, 0, 0);
    }
   
    
    
    // Семплируем карту нормалей
        float3 normalMapSample = gNormalMap.Sample(gSamAnisotropicWrap, pin.TexC).rgb;
    
    // Нормализуем интерполированные нормали и тангенты
    pin.NormalW = normalize(pin.NormalW);
    pin.TangentW = normalize(pin.TangentW);
    
    // Вычисляем финальную нормаль с учетом normal map
    float3 bumpedNormalW = NormalSampleToWorldSpace(normalMapSample, pin.NormalW, pin.TangentW);
    
    // Выводим в G-Buffer
    if (renderHMAP > 0.5f)
        pout.Albedo = gHeightMap.Sample(gSamAnisotropicWrap, pin.TexC).rgba;
    else
        pout.Albedo = diffuseAlbedo;
    pout.Normal = float4(bumpedNormalW, gRoughness);
    pout.Position = float4(pin.PosW, 1.0f);
    
    return pout;
}
