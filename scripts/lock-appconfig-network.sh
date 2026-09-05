#!/bin/sh
# azd postprovision hook: closes public network access on the App Configuration store.
#
# ARM writes App Configuration key-values over the data plane. It cannot reach a store that is
# only exposed through a private endpoint unless the deployment runs inside the VNet, so the
# store is provisioned with public network access enabled and locked down here, after the
# key-values have been written. Local authentication is disabled the whole time, so the store
# never accepts anything but Entra credentials.
set -eu

if [ -z "${APP_CONFIG_NAME:-}" ] || [ -z "${AZURE_RESOURCE_GROUP:-}" ]; then
  echo "APP_CONFIG_NAME or AZURE_RESOURCE_GROUP is not set; leaving App Configuration network access unchanged." >&2
  exit 0
fi

if [ "${PUBLIC_NETWORK_ACCESS:-Disabled}" = "Enabled" ]; then
  echo "PUBLIC_NETWORK_ACCESS is Enabled; leaving App Configuration '$APP_CONFIG_NAME' publicly reachable."
  exit 0
fi

echo "Disabling public network access on App Configuration '$APP_CONFIG_NAME'..."
# Retried because this runs at the tail of a long deployment, where transient
# management.azure.com timeouts are common and would otherwise leave the store open.
attempt=1
while [ "$attempt" -le 5 ]; do
  if az appconfig update --name "$APP_CONFIG_NAME" --resource-group "$AZURE_RESOURCE_GROUP" \
    --enable-public-network false --only-show-errors --output none; then
    echo "App Configuration '$APP_CONFIG_NAME' is now reachable only through its private endpoint."
    exit 0
  fi
  if [ "$attempt" -lt 5 ]; then
    echo "Attempt $attempt failed; retrying in $((attempt * 5))s..." >&2
    sleep $((attempt * 5))
  fi
  attempt=$((attempt + 1))
done

echo "Failed to disable public network access on App Configuration '$APP_CONFIG_NAME'. Re-run 'azd provision', or run: az appconfig update --name $APP_CONFIG_NAME --resource-group $AZURE_RESOURCE_GROUP --enable-public-network false" >&2
exit 1
