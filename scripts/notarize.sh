#!/usr/bin/env bash

set -euo pipefail

artifact="${1:?artifact path is required}"

submit_for_notarization() {
  local target="$1"
  local result submission_id status

  if [ -n "${NOTARY_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
    result="$(xcrun notarytool submit "$target" \
      --key "$NOTARY_API_KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER_ID" \
      --wait \
      --output-format json)"
  else
    result="$(xcrun notarytool submit "$target" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_ID_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait \
      --output-format json)"
  fi

  status="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
  submission_id="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')"

  if [ "$status" != "Accepted" ]; then
    echo "Notarization failed for $target with status: $status"
    if [ -n "$submission_id" ]; then
      if [ -n "${NOTARY_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
        xcrun notarytool log "$submission_id" \
          --key "$NOTARY_API_KEY_PATH" \
          --key-id "$APPLE_API_KEY_ID" \
          --issuer "$APPLE_API_ISSUER_ID"
      else
        xcrun notarytool log "$submission_id" \
          --apple-id "$APPLE_ID" \
          --password "$APPLE_ID_PASSWORD" \
          --team-id "$APPLE_TEAM_ID"
      fi
    fi
    exit 1
  fi
}

submit_for_notarization "$artifact"
