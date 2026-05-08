#!/bin/bash

# 이미지 태그 자동 업데이트 스크립트
# 사용법: ./scripts/update-image-tags.sh [commit-sha]
# 예: ./scripts/update-image-tags.sh a1b2c3d4e5f6

set -e

COMMIT_SHA=${1:-$(git rev-parse --short HEAD)}

if [ -z "$COMMIT_SHA" ]; then
    echo "❌ Cannot determine commit SHA"
    exit 1
fi

KUSTOMIZATION_FILE="k8s/overlays/prod/kustomization.yaml"

if [ ! -f "$KUSTOMIZATION_FILE" ]; then
    echo "❌ Kustomization file not found: $KUSTOMIZATION_FILE"
    exit 1
fi

echo "🔄 Updating image tags with commit SHA: $COMMIT_SHA"
echo ""

# 각 서비스의 newTag 업데이트
# 포맷: newTag: "latest"  → newTag: "sha-a1b2c3d4"

sed -i.bak "/medical-service-frontend/,/newTag:/ s/newTag: \".*\"/newTag: \"sha-$COMMIT_SHA\"/" "$KUSTOMIZATION_FILE"
sed -i.bak "/medical-service-backend/,/newTag:/ s/newTag: \".*\"/newTag: \"sha-$COMMIT_SHA\"/" "$KUSTOMIZATION_FILE"
sed -i.bak "/medical-service-ai/,/newTag:/ s/newTag: \".*\"/newTag: \"sha-$COMMIT_SHA\"/" "$KUSTOMIZATION_FILE"

# 백업 파일 제거
rm -f "$KUSTOMIZATION_FILE.bak"

echo "✅ Image tags updated:"
echo ""
grep -A 1 "newName:" "$KUSTOMIZATION_FILE" | grep -E "(newName|newTag)" || echo "No matches found"

echo ""
echo "📝 Next steps:"
echo "   git add $KUSTOMIZATION_FILE"
echo "   git commit -m \"ci: update image tags to sha-$COMMIT_SHA\""
echo "   git push origin main"
