// ==================================================================================
// TaaResolve.hlsl - Шейдер для временного сглаживания
// ==================================================================================

#define MaxLights 16

// Структуры (должны совпадать с C++)
struct Light
{
    float3 Strength;
    float  FalloffStart;
    float3 Direction;
    float  FalloffEnd;
    float3 Position;
    float  SpotPower;
};

cbuffer PassCB : register(b1)
{
    float4x4 gView;
    float4x4 gInvView;
    float4x4 gProj;
    float4x4 gInvProj;
    float4x4 gViewProj;
    float4x4 gInvViewProj;
    float4x4 gViewProjTex;
    float4x4 gShadowTransform;

    float3   gEyePosW; float _pad0;

    float2   gRT;             // RenderTargetSize
    float2   gInvRT;          // InvRenderTargetSize
    float    gNearZ;
    float    gFarZ;
    float    gTotalTime;
    float    gDeltaTime;

    float4   gAmbientLight;
    Light    gLights[MaxLights];

    // === TAA Params ===
    float4x4 gPrevViewProj;   // Матрица ViewProj прошлого кадра
    float2   gJitter;         // Текущий сдвиг
    float2   gPrevJitter;     // Сдвиг прошлого кадра (обычно 0, если не храним историю джиттера)

    float2   gInvRT_TAA;      
    float2   gInvRT_dup;

    float    gTaaFeedback;    // Сила смешивания (0.9 - много истории, 0.1 - мало)
    float    gTaaDepthThresh; // Порог изменения глубины для сброса истории
    int      gTaaMode;        // Режим отладки
    int      gTaaEnabledInt;  // 1 = вкл, 0 = выкл

    float2   _taaPad;
    
    // Debug skull params
    float3   gSkullCenterWS; float gSkullRadius;
    float4x4 gInvSkullWorld;
    float3   gSkullExtentsLS; float _skullPad;
};

// Ресурсы
Texture2D gCurr    : register(t0); // Текущий отрендеренный кадр (с джиттером)
Texture2D gHistory : register(t1); // Кадр прошлого сглаживания
Texture2D gDepth   : register(t2); // Глубина текущего кадра

SamplerState gsamLinearClamp : register(s3);
SamplerState gsamPointClamp  : register(s0); 

struct VSOut
{
    float4 PosH : SV_Position;
    float2 Tex  : TEXCOORD0;
};

// ==================================================================================
// ВЕРШИННЫЙ ШЕЙДЕР (Full Screen Quad)
// ==================================================================================
VSOut VS_FullscreenTriangle(uint vid : SV_VertexID)
{
    VSOut o;
    // Генерируем треугольник на весь экран без вершинного буфера
    float2 pos = (vid == 0) ? float2(-1.0, -1.0) :
                 (vid == 1) ? float2( 3.0, -1.0) :
                              float2(-1.0,  3.0);

    o.PosH = float4(pos, 0.0, 1.0);
    o.Tex.x = 0.5f * (pos.x + 1.0f);
    o.Tex.y = 1.0f - 0.5f * (pos.y + 1.0f); // Инвертируем Y для текстур
    return o;
}

// ==================================================================================
// ПОМОЩНИКИ
// ==================================================================================

// Восстановление мировой позиции пикселя по его UV и глубине
float3 GetWorldPosition(float2 uv, float depth)
{
    // 1. UV [0..1] -> NDC [-1..1]
    float2 ndc = uv * 2.0f - 1.0f;
    ndc.y = -ndc.y; // DirectX NDC Y растет вверх

    // 2. Unproject: NDC -> World
    // Используем gInvViewProj. Так как эта матрица обратна той, что использовалась при рендере
    // (включая джиттер), она корректно восстановит мировую позицию поверхности.
    float4 posH = float4(ndc, depth, 1.0f);
    float4 posW = mul(posH, gInvViewProj);
    return posW.xyz / posW.w;
}

// 3x3 Neighborhood Clamping (Убирает гостинг)
// Мы находим мин/макс цвет в районе 3x3 пикселей вокруг текущего
// и "притягиваем" цвет истории к этому диапазону.
float3 ClipHistory(float3 history, float3 cMin, float3 cMax)
{
    // Самый простой вариант - Clamp (обрезание)
    return clamp(history, cMin, cMax);
}

// ==================================================================================
// ПИКСЕЛЬНЫЙ ШЕЙДЕР
// ==================================================================================
float4 PS_TAA(VSOut i) : SV_Target
{
    float2 uv = i.Tex;
    
    // 1. Читаем текущий цвет (Center)
    float4 currColor = gCurr.SampleLevel(gsamLinearClamp, uv, 0);

    // Если TAA выключен глобально - просто возвращаем текущий кадр
    if (gTaaEnabledInt == 0) 
    {
        return currColor;
    }

    // 2. Читаем глубину
    float depth = gDepth.SampleLevel(gsamPointClamp, uv, 0).r;

    // 3. Вычисляем Вектор Скорости (Velocity) через репроекцию
    //    Находим, где этот пиксель был в прошлом кадре.
    float3 worldPos = GetWorldPosition(uv, depth);
    float4 prevClip = mul(float4(worldPos, 1.0f), gPrevViewProj); // World -> Prev Clip
    float2 prevNdc  = prevClip.xy / prevClip.w;
    
    // Prev NDC -> Prev UV
    float2 prevUv = prevNdc * float2(0.5f, -0.5f) + 0.5f;

    // 4. Проверка: не вылетели ли мы за экран в прошлом кадре?
    bool isOffScreen = any(prevUv < 0.0f) || any(prevUv > 1.0f);
    if (isOffScreen)
    {
        return currColor; // Истории нет, возвращаем текущий
    }

    // 5. Читаем историю (History)
    float4 historyColor = gHistory.SampleLevel(gsamLinearClamp, prevUv, 0);

    // 6. Anti-Ghosting: Собираем статистику окрестности 3x3
    //    Нужно найти Min и Max цвет вокруг текущего пикселя.
    float3 cMin = currColor.rgb;
    float3 cMax = currColor.rgb;

    [unroll]
    for(int y = -1; y <= 1; ++y)
    {
        [unroll]
        for(int x = -1; x <= 1; ++x)
        {
            if(x == 0 && y == 0) continue;
            
            // Смещение в текселях
            float2 offset = float2(x, y) * gInvRT; 
            float3 neighbor = gCurr.SampleLevel(gsamLinearClamp, uv + offset, 0).rgb;
            
            cMin = min(cMin, neighbor);
            cMax = max(cMax, neighbor);
        }
    }

    // 7. Корректируем историю (Clamp)
    //    Если цвет истории сильно отличается от соседей текущего кадра, 
    //    значит это "старый" след (гостинг), и мы его обрезаем.
    historyColor.rgb = ClipHistory(historyColor.rgb, cMin, cMax);

    // 8. Смешивание (Blend)
    //    Вычисляем коэффициент смешивания. 
    float feedback = gTaaFeedback; // Базовое значение (например 0.9)

    // Если глубина сильно изменилась (объект перекрыл другой), сбрасываем историю
    // (Это простая эвристика, velocity buffer был бы точнее)
    // Проверяем глубину в точке, откуда мы "прилетели"
    /* Этот блок можно включить для улучшения краев, но он может давать артефакты на тонких объектах.
       Пока оставим простую проверку: если пиксель очень далеко (небо), смешиваем меньше или больше.
    */
    
    // Финальный Lerp:
    // result = curr * (1 - feedback) + hist * feedback
    float4 result = lerp(currColor, historyColor, feedback);

    // =======================================
    // Debug Modes (для отладки через переменную mTaaViewMode)
    // =======================================
    if (gTaaMode == 1) return currColor;                             // Только текущий (дрожащий)
    if (gTaaMode == 2) return historyColor;                          // Только история
    if (gTaaMode == 3) return float4(abs(currColor.rgb - historyColor.rgb) * 10.0, 1.0); // Разница

    return result;
}