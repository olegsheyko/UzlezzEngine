#include "TerrainSystem.h"

bool QuadTreeNode::ShouldSplit(const XMFLOAT3& cameraPos, float heightscale, int mapsize) const
{
    auto camPos = cameraPos;
    camPos.y = 0;
    XMVECTOR camPosVec = XMLoadFloat3(&camPos);
    float lodneeddist = ( mapsize/2.0f - depth * mapsize/16.0f);
    BoundingSphere sphere;
    sphere.Center = cameraPos;
    sphere.Radius = lodneeddist;
    return sphere.Intersects(boundingBox);
}

void QuadTreeNode::UpdateVisibility(BoundingFrustum& frustum, const XMFLOAT3& cameraPos,
    std::vector<TerrainTile*>& visibleTiles, float heightscale, int mapsize)
{
    if (frustum.Contains(boundingBox) == DISJOINT)
    {
        return;
    }
    if (!children[0] || !ShouldSplit(cameraPos, heightscale, mapsize))
    {
        if (tile)
        {
            visibleTiles.push_back(tile);
        }
    }
    else
    {
        for (int i = 0; i < 4; i++)
        {
            if (children[i])
            {
                children[i]->UpdateVisibility(frustum, cameraPos, visibleTiles, heightscale, mapsize);
            }
        }
    }
}

void TerrainSystem::Initialize(ID3D12Device* device, int HeightMapIndex, std::string hmapname, float worldSize,
    int maxLOD)
{
    m_worldSize = worldSize;
    m_hmapIndex = HeightMapIndex;
    m_hmapname = hmapname;
    m_maxLOD = maxLOD;
    m_heightScale = 50.0f;
    m_rootNode = std::make_unique<QuadTreeNode>();
    m_rootNode->depth = 0;
    int initialSize = (int)worldSize;
    BuildQuadTree(m_rootNode.get(), 0, 0, initialSize, 0);

}

void TerrainSystem::Update(const XMFLOAT3& cameraPos, BoundingFrustum& frustum)
{
    m_visibleTiles.clear();
    if (m_rootNode)
        m_rootNode->UpdateVisibility(frustum, cameraPos, m_visibleTiles, m_heightScale, (int)m_worldSize);
}

std::vector<std::unique_ptr<TerrainTile>>& TerrainSystem::GetAllTiles()
{
    return m_allTiles;
}

void TerrainSystem::GetVisibleTiles(std::vector<TerrainTile*>& visibleTiles)
{
    visibleTiles = m_visibleTiles;
}

void TerrainSystem::BuildQuadTree(QuadTreeNode* node, int x, int y, int size, int depth)
{
    node->depth = depth;
    float tileSize = m_worldSize / (1 << depth);
    node->boundingBox = CalculateTileAABB(XMFLOAT3((float)x, 0, (float)y), tileSize, -10.0f, 400.0f);

    auto tile = std::make_unique<TerrainTile>();
    tile->worldPos = XMFLOAT3((float)x, 0, (float)y);
    tile->lodLevel = depth;
    tile->tileSize = tileSize;
    tile->isVisible = true;
    tile->boundingBox = node->boundingBox;
    tile->tileIndex = tileIndex++;
    m_allTiles.push_back(std::move(tile));
    node->tile = m_allTiles.back().get(); // Указываем на созданный тайл
    // Если мы достигли максимальной глубины, создаем тайл.
    if (depth != m_maxLOD)
    {
        int halfSize = size / 2;
        for (int i = 0; i < 4; i++)
        {
            node->children[i] = std::make_unique<QuadTreeNode>();
            int childX = x + (i % 2) * halfSize;
            int childY = y + (i / 2) * halfSize;
            BuildQuadTree(node->children[i].get(), childX, childY, halfSize, depth + 1);
        }
    }
}

BoundingBox TerrainSystem::CalculateTileAABB(const XMFLOAT3& pos, float size, float minHeight, float maxHeight)
{
    BoundingBox aabb;
    auto minPoint = XMFLOAT3(pos.x, 0, pos.z);
    auto maxPoint = XMFLOAT3(pos.x + size, 100, pos.z + size); // 200 = maxheightscale
    XMVECTOR pt1 = XMLoadFloat3(&minPoint);
    XMVECTOR pt2 = XMLoadFloat3(&maxPoint);
    BoundingBox::CreateFromPoints(aabb, pt1, pt2);
    return aabb;
}
