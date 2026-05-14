#!/bin/bash
set -euxo pipefail
IMAGE_FILE=/opt/medical-backend-image
if [[ -f "$IMAGE_FILE" ]]; then
  dnf install -y docker
  systemctl enable --now docker
  IMG=$(tr -d '\r\n' < "$IMAGE_FILE")
  docker pull "$IMG" || true
  docker stop medicare-backend 2>/dev/null || true
  docker rm medicare-backend 2>/dev/null || true
  if [[ -f /opt/medical-backend.env ]]; then
    docker run -d --name medicare-backend --restart always -p 3000:3000 --env-file /opt/medical-backend.env "$IMG"
  else
    docker run -d --name medicare-backend --restart always -p 3000:3000 "$IMG"
  fi
else
  dnf install -y python3
  cd /tmp
  nohup python3 -m http.server 3000 --bind 0.0.0.0 >/var/log/placeholder-http.log 2>&1 &
fi
