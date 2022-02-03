#!/bin/ash

SERVICE_NAME=$(echo $DIUN_ENTRY_IMAGE | sed -E 's/.*\/([^\:]+)\:.*/\1/')
DEVICE_NAME="${HOME_ASSISTANT_ACCESS_DEVICE_NAME}_${SERVICE_NAME}"
FRIENDLY_NAME="${SERVICE_NAME} service version"
STATUS=$DIUN_ENTRY_STATUS

curl -X POST -H "Authorization: Bearer $HOME_ASSISTANT_ACCESS_TOKEN" \
       -H "Content-Type: application/json" \
       -d "{\"state\": \"${STATUS}\", \"attributes\": { \"friendly_name\": \"${FRIENDLY_NAME}\"}}" \
       "http://${HOME_ASSISTANT_HOST}:${HOME_ASSISTANT_PORT}/api/states/sensor.${DEVICE_NAME}"