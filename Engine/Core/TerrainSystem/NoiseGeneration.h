#pragma once
#include "d3dUtil.h"
using namespace DirectX;
using namespace DirectX::PackedVector;
using namespace Microsoft::WRL;
// Операции над векторами XMFLOAT2, используемые при генерации шума

inline XMFLOAT2 operator*(const XMFLOAT2& v, float s)
{
	return XMFLOAT2(v.x * s, v.y * s);
}

inline XMFLOAT2 operator*(float s, const XMFLOAT2& v)
{
	return XMFLOAT2(v.x * s, v.y * s);
}

inline XMFLOAT2 operator*(const XMFLOAT2& v1, const XMFLOAT2& v2)
{
	return XMFLOAT2(v1.x * v2.x, v1.y * v2.y);
}

inline XMFLOAT2 operator+(const XMFLOAT2& v1, const XMFLOAT2& v2)
{
	return XMFLOAT2(v1.x + v2.x, v1.y + v2.y);
}

inline XMFLOAT2 operator+(const XMFLOAT2& v, float s)
{
	return XMFLOAT2(v.x + s, v.y + s);
}

inline XMFLOAT2 operator+(float s, const XMFLOAT2& v)
{
	return XMFLOAT2(v.x + s, v.y + s);
}

inline XMFLOAT2 operator-(const XMFLOAT2& v1, const XMFLOAT2& v2)
{
	return XMFLOAT2(v1.x - v2.x, v1.y - v2.y);
}

inline XMFLOAT2 operator-(const XMFLOAT2& v, float s)
{
	return XMFLOAT2(v.x - s, v.y - s);
}

inline XMFLOAT2 operator-(float s, const XMFLOAT2& v)
{
	return XMFLOAT2(s - v.x, s - v.y);
}

inline XMFLOAT2 operator-(const XMFLOAT2& v)
{
	return XMFLOAT2(-v.x, -v.y);
}

inline float lerp(float a, float b, float t)
{
	return a + t * (b - a);
}

inline XMFLOAT2 vecmul(XMFLOAT2& v1, XMFLOAT2& v2)
{
	return XMFLOAT2(v1.x * v2.x, v1.y * v2.y);
}
inline XMFLOAT2 vecmul(XMFLOAT2& v1, float f)
{
	return XMFLOAT2(v1.x * f, v1.y * f);
}
inline float frac(float x)
{
	return x - std::floor(x);
}
inline XMFLOAT2 frac(XMFLOAT2 v)
{
	return v - XMFLOAT2(frac(v.x), frac(v.y));
}

// Класс генератора фрактального шума (Value Noise + FBM)
struct NoiseGenerator
{
	NoiseGenerator() {};
	int OCTAVES = 5;              // Количество октав (слоёв) шума
	float LACUNARITY = 2.0f;      // Масштаб частоты между октавами
	float PERSISTENCE = 0.5f;     // Затухание амплитуды между октавами
	float amplitude = 1.0f;       // Начальная амплитуда
	float frequency = 1.0f;       // Начальная частота
	float maxValue = 0.0f;        // Суммарная теоретическая амплитуда (для нормализации)
	XMFLOAT2 offset = XMFLOAT2(7.f, 15.f); // Смещение координат (движение шума)
	ComPtr<ID3D12Resource> GenerateNoiseTexture(ID3D12Device* device, ID3D12GraphicsCommandList* cmdList, int width, int height, ComPtr<ID3D12Resource>& uploadBuffer);
private:
	float hash2D(XMFLOAT2 p);     // Простейший хэш для генерации псевдослучайных значений
	XMFLOAT2 fade(XMFLOAT2 t);    // Quintic-функция сглаживания
	float noise2D(XMFLOAT2 p);    // 2D Value Noise
	float FBM_Noise(XMFLOAT2 p);  // Фрактальный шум (сумма октав)
};
