#include "NoiseGeneration.h"
// Функция сглаживания (quintic/smoothstep)
// f(t) = 6t^5 - 15t^4 + 10t^3. Обеспечивает C2-непрерывность.
XMFLOAT2 NoiseGenerator::fade(XMFLOAT2 t)
{
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}
float NoiseGenerator::hash2D(XMFLOAT2 p)
{
	// Простейший процедурный хэш для 2D-точки
	float h = p.x * 12.9898f + p.y * 78.233f;
	return frac(std::sin(h) * 43758.5453123f);
}
// 2D Value Noise (на основе идеи Перлина)
// Возвращает значение шума в диапазоне [0, 1]
float NoiseGenerator::noise2D(XMFLOAT2 p)
{
    // 1) Целая часть координаты — идентификатор ячейки
    XMFLOAT2 i(std::floor(p.x), std::floor(p.y));

    // 2) Дробная часть — локальная позиция внутри ячейки [0,1)
    XMFLOAT2 f(frac(p.x), frac(p.y));

    // 3) Псевдослучайные значения в четырёх углах ячейки
    float a = hash2D(i);
    float b = hash2D(i + XMFLOAT2(1.0f, 0.0f));
    float c = hash2D(i + XMFLOAT2(0.0f, 1.0f));
    float d = hash2D(i + XMFLOAT2(1.0f, 1.0f));

    // 4) Сглаживаем дробную часть (fade)
    XMFLOAT2 u = fade(f);

    // 5) Билинейная интерполяция (lerp)
    return lerp(
        lerp(a, b, u.x), // интерполяция по X (нижняя грань)
        lerp(c, d, u.x), // интерполяция по X (верхняя грань)
        u.y              // интерполяция по Y
    );
}
// FBM (Fractal Brownian Motion)
// Суммирование нескольких октав Value Noise для получения детализированного результата
float NoiseGenerator::FBM_Noise(XMFLOAT2 p)
{
    // Сдвиг входных координат на смещение
	p = p + offset;

    float total = 0.0f;
    float amplitude = this->amplitude;
    float frequency = this->frequency;
    float maxValue = this->maxValue;

    for (int i = 0; i < OCTAVES; i++)
    {
        total += noise2D(p * frequency) * amplitude;
        maxValue += amplitude;
        amplitude *= PERSISTENCE;
        frequency *= LACUNARITY;
    }

    // Нормализация результата в диапазон [0, 1]
    return total / maxValue;
}


ComPtr<ID3D12Resource>NoiseGenerator::GenerateNoiseTexture(ID3D12Device* device,
	ID3D12GraphicsCommandList* cmdList,
	int width,
	int height,
	ComPtr<ID3D12Resource>& uploadBuffer)
{
	// Подготавливаем буфер данных для текстуры: формат RGBA32_FLOAT (4 float на пиксель)
	std::vector<float> textureData(width * height * 4);

	// Заполняем массив данных текстуры
	for (int i = 0; i < width * height * 4; i += 4)
	{
		int pixelIndex = i / 4;

		// Координаты пикселя и преобразование в UV
		int x = pixelIndex % width;
		int y = pixelIndex / width;
		float u = (float)x / width * 8;
		float v = (float)y / height * 8;
		float noise = FBM_Noise(XMFLOAT2(u, v));
		textureData[i + 0] = noise; // R
		textureData[i + 1] = noise; // G
		textureData[i + 2] = noise; // B
		textureData[i + 3] = 1;     // A
	}

	// Описание ресурса текстуры
	D3D12_RESOURCE_DESC textureDesc = {};
	textureDesc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
	textureDesc.Alignment = 0;
	textureDesc.Width = width;
	textureDesc.Height = height;
	textureDesc.DepthOrArraySize = 1;
	textureDesc.MipLevels = 1;
	textureDesc.Format = DXGI_FORMAT_R32G32B32A32_FLOAT;
	textureDesc.SampleDesc.Count = 1;
	textureDesc.SampleDesc.Quality = 0;
	textureDesc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
	textureDesc.Flags = D3D12_RESOURCE_FLAG_NONE;

	// Создаём ресурс текстуры на GPU
	ComPtr<ID3D12Resource> texture;
	ThrowIfFailed(device->CreateCommittedResource(
		&CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_DEFAULT),
		D3D12_HEAP_FLAG_NONE,
		&textureDesc,
		D3D12_RESOURCE_STATE_COPY_DEST,
		nullptr,
		IID_PPV_ARGS(&texture)));

	// Вычисляем размер буфера для копирования (upload buffer)
	UINT64 uploadBufferSize = GetRequiredIntermediateSize(texture.Get(), 0, 1);

	// Создаём upload-буфер
	ThrowIfFailed(device->CreateCommittedResource(
		&CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_UPLOAD),
		D3D12_HEAP_FLAG_NONE,
		&CD3DX12_RESOURCE_DESC::Buffer(uploadBufferSize),
		D3D12_RESOURCE_STATE_GENERIC_READ,
		nullptr,
		IID_PPV_ARGS(&uploadBuffer)));

	// Описываем подресурс для копирования данных в текстуру
	D3D12_SUBRESOURCE_DATA textureDataDesc = {};
	textureDataDesc.pData = textureData.data();
	textureDataDesc.RowPitch = width * 4 * sizeof(float); // 4 float на пиксель
	textureDataDesc.SlicePitch = textureDataDesc.RowPitch * height;

	// Копируем данные в текстуру
	UpdateSubresources(cmdList, texture.Get(), uploadBuffer.Get(),
		0, 0, 1, &textureDataDesc);

	// Переводим ресурс в состояние выборки пиксельным шейдером
	cmdList->ResourceBarrier(1, &CD3DX12_RESOURCE_BARRIER::Transition(
		texture.Get(),
		D3D12_RESOURCE_STATE_COPY_DEST,
		D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE));

	return texture;
}