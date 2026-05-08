#!/bin/bash

# 배포 자동화 스크립트
# 사용법: ./scripts/deploy.sh [dev|prod] [image-tags-file]
# 예: ./scripts/deploy.sh prod image-tags.txt

set -e

ENVIRONMENT=${1:-prod}
IMAGE_TAGS_FILE=${2:-""}

if [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "prod" ]; then
    echo "❌ Usage: $0 [dev|prod] [optional: image-tags-file]"
    echo ""
    echo "Examples:"
    echo "  $0 prod                          # Deploy prod with current kustomization"
    echo "  $0 prod image-tags.txt           # Deploy prod and update image tags"
    exit 1
fi

KUSTOMIZATION_PATH="k8s/overlays/$ENVIRONMENT"

if [ ! -d "$KUSTOMIZATION_PATH" ]; then
    echo "❌ Kustomization path not found: $KUSTOMIZATION_PATH"
    exit 1
fi

echo "🚀 Deploying to $ENVIRONMENT environment..."
echo "📁 Using kustomization: $KUSTOMIZATION_PATH"

# 이미지 태그 파일이 제공되면 업데이트
if [ -n "$IMAGE_TAGS_FILE" ] && [ -f "$IMAGE_TAGS_FILE" ]; then
    echo "🔄 Updating image tags from $IMAGE_TAGS_FILE..."
    
    # 파일 형식: frontend=sha-xxxx, backend=sha-yyyy, ai=sha-zzzz
    # 각 줄에서 태그 읽기
    while IFS='=' read -r service tag; do
        service=$(echo "$service" | xargs)  # trim whitespace
        tag=$(echo "$tag" | xargs)
        
        if [ -z "$service" ] || [ -z "$tag" ]; then
            continue
        fi
        
        echo "  📦 $service: $tag"
        
        # kustomization.yaml의 newTag 업데이트
        case "$service" in
            frontend)
                sed -i "s/<FRONTEND_IMAGE_PLACEHOLDER>-tag:.*/newTag: \"$tag\"/" "$KUSTOMIZATION_PATH/kustomization.yaml" || true
                ;;
            backend)
                sed -i "s/<BACKEND_IMAGE_PLACEHOLDER>-tag:.*/newTag: \"$tag\"/" "$KUSTOMIZATION_PATH/kustomization.yaml" || true
                ;;
            ai)
                sed -i "s/<AI_IMAGE_PLACEHOLDER>-tag:.*/newTag: \"$tag\"/" "$KUSTOMIZATION_PATH/kustomization.yaml" || true
                ;;
        esac
    done < "$IMAGE_TAGS_FILE"
fi

# Kustomize 빌드
echo "🔨 Building manifests with kustomize..."
MANIFESTS=$(mktemp)
kustomize build "$KUSTOMIZATION_PATH" > "$MANIFESTS"

if [ ! -s "$MANIFESTS" ]; then
    echo "❌ Kustomize build failed or no output generated"
    rm -f "$MANIFESTS"
    exit 1
fi

echo "✅ Manifests generated successfully"
echo ""

# kubectl apply 실행
echo "📍 Applying manifests to Kubernetes..."
kubectl apply -f "$MANIFESTS"

# 정리
rm -f "$MANIFESTS"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "📊 Verify deployment status:"
echo "   kubectl get deployments"
echo "   kubectl get pods"
echo "   kubectl get services"
