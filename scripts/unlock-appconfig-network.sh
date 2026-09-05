#!/bin/sh
# azd preprovision hook: reopens public network access on the App Configuration store.
#
# ARM writes App Configuration key-values over the data plane, which it cannot reach through a
# private endpoint unless the deployment runs inside the VNet. The postprovision hook closes the
# store after each provision, so it has to be reopened before the next one.
#
# Doing this here rather than relying on the Bicep template alone avoids a race: a network rule
# change made *during* the deployment takes up to a minute to reach the data plane, so the
# key-value writes in the same deployment can still be rejected with Forbidden.
set -eu

if [ -z "${APP_CONFIG_NAME:-}" ] || [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  echo "App Configuration store not provisioned yet; nothing to reopen."
  exit 0
fi

if ! az appconfig show --name "$APP_CONFIG_NAME" --resource-group "$AZURE_RESOURCE_GROUP" \
  --only-show-errors --output none 2>/dev/null; then
  echo "App Configuration '$APP_CONFIG_NAME' does not exist yet; nothing to reopen."
  exit 0
fi

echo "Temporarily allowing public network access on App Configuration '$APP_CONFIG_NAME' so ARM can write key-values..."
attempt=1
while [ "$attempt" -le 5 ]; do
  if az appconfig update --name "$APP_CONFIG_NAME" --resource-group "$AZURE_RESOURCE_GROUP" \
    --enable-public-network true --only-show-errors --output none; then
    # The data plane picks up network rule changes asynchronously.
    sleep 60
    exit 0
  fi
  if [ "$attempt" -lt 5 ]; then
    echo "Attempt $attempt failed; retrying in $((attempt * 5))s..." >&2
    sleep $((attempt * 5))
  fi
  attempt=$((attempt + 1))
done

echo "Failed to enable public network access on App Configuration '$APP_CONFIG_NAME'." >&2
exit 1
