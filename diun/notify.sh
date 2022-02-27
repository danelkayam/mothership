#!/bin/ash

IMAGE_NAME=$(echo $DIUN_ENTRY_IMAGE | sed -E 's/.*\/([^\:]+)\:.*/\1/')
NAME=$DIUN_ENTRY_IMAGE
STATUS=$DIUN_ENTRY_STATUS

curl -X POST -H "X-API-Key: $DIUNSTORE_SECRET_API_KEY" \
       -H "Content-Type: application/json" \
       -d "{\"image\": \"${IMAGE_NAME}\", \"name\": \"${NAME}\", \"state\": \"${STATUS}\"}" \
       "http://${DIUNSTORE_HOST}:${DIUNSTORE_PORT}/api/containers"