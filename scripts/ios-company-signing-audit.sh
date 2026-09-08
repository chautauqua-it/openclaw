#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/ios"
CONFIG_PATH="${1:-${IOS_DIR}/build/BetaRelease.xcconfig}"
EXPECTED_TEAM="${IOS_DEVELOPMENT_TEAM:-}"
EXPECTED_BASE="${IOS_BETA_BUNDLE_ID_BASE:-it.differen.openclaw}"

[[ -f "${CONFIG_PATH}" ]] || { echo "Missing beta signing config." >&2; exit 1; }
[[ "${EXPECTED_TEAM}" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "IOS_DEVELOPMENT_TEAM must be the explicit 10-character Differen organization Team ID." >&2
  exit 1
}

value_for() {
  local key="$1"
  awk -F= -v key="${key}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "${CONFIG_PATH}"
}

assert_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(value_for "${key}")"
  [[ "${actual}" == "${expected}" ]] || {
    echo "Signing audit failed for ${key}." >&2
    exit 1
  }
}

assert_value OPENCLAW_CODE_SIGN_STYLE Automatic
assert_value OPENCLAW_CODE_SIGN_IDENTITY "Apple Distribution"
assert_value OPENCLAW_DEVELOPMENT_TEAM "${EXPECTED_TEAM}"
assert_value OPENCLAW_IOS_SELECTED_TEAM "${EXPECTED_TEAM}"
assert_value OPENCLAW_APP_BUNDLE_ID "${EXPECTED_BASE}"
assert_value OPENCLAW_SHARE_BUNDLE_ID "${EXPECTED_BASE}.share"
assert_value OPENCLAW_ACTIVITY_WIDGET_BUNDLE_ID "${EXPECTED_BASE}.activitywidget"
assert_value OPENCLAW_INTENTS_BUNDLE_ID "${EXPECTED_BASE}.intents"
assert_value OPENCLAW_WATCH_APP_BUNDLE_ID "${EXPECTED_BASE}.watchkitapp"
assert_value OPENCLAW_WATCH_EXTENSION_BUNDLE_ID "${EXPECTED_BASE}.watchkitapp.extension"
assert_value OPENCLAW_WATCH_CONTROL_WIDGET_BUNDLE_ID "${EXPECTED_BASE}.watchkitapp.controlwidget"

for profile_key in \
  OPENCLAW_APP_PROFILE \
  OPENCLAW_SHARE_PROFILE \
  OPENCLAW_ACTIVITY_WIDGET_PROFILE \
  OPENCLAW_INTENTS_PROFILE \
  OPENCLAW_WATCH_APP_PROFILE \
  OPENCLAW_WATCH_EXTENSION_PROFILE \
  OPENCLAW_WATCH_CONTROL_WIDGET_PROFILE; do
  grep -Eq "^[[:space:]]*${profile_key}[[:space:]]*=" "${CONFIG_PATH}" || {
    echo "Signing audit missing ${profile_key}." >&2
    exit 1
  }
done

grep -Fq 'CODE_SIGN_IDENTITY: "$(OPENCLAW_CODE_SIGN_IDENTITY)"' "${IOS_DIR}/project.yml"
! grep -Fq 'CODE_SIGN_IDENTITY: "Apple Development"' "${IOS_DIR}/project.yml"
/usr/bin/plutil -lint "${IOS_DIR}/Sources/OpenClaw.entitlements" >/dev/null
/usr/bin/plutil -lint "${IOS_DIR}/Sources/OpenClaw.Release.entitlements" >/dev/null
grep -A1 -F '<key>aps-environment</key>' "${IOS_DIR}/Sources/OpenClaw.Release.entitlements" | grep -Fq '<string>production</string>'
! grep -Fq 'com.apple.developer.carplay' "${IOS_DIR}/Sources/OpenClaw.Release.entitlements"

echo "PASS: Iànua company signing matrix is explicit, distribution-scoped and CarPlay-free for Release."
