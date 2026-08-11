#!/bin/sh

set -eu

relay_url="${PASS_PUBLIC_RELAY_URL:-}"
issuer="${PASS_OIDC_ISSUER:-}"
client_id="${PASS_OIDC_CLIENT_ID:-}"
audience="${PASS_OIDC_AUDIENCE:-}"

if [ "${CONFIGURATION:-}" = "Release" ] && [ -z "$relay_url" ]; then
    echo "error: PASS_PUBLIC_RELAY_URL is required for Release builds." >&2
    exit 1
fi

configured_oidc_values=0
[ -n "$issuer" ] && configured_oidc_values=$((configured_oidc_values + 1))
[ -n "$client_id" ] && configured_oidc_values=$((configured_oidc_values + 1))
[ -n "$audience" ] && configured_oidc_values=$((configured_oidc_values + 1))

if [ "$configured_oidc_values" -ne 0 ] && [ "$configured_oidc_values" -ne 3 ]; then
    echo "error: PASS_OIDC_ISSUER, PASS_OIDC_CLIENT_ID, and PASS_OIDC_AUDIENCE must be configured together." >&2
    exit 1
fi
