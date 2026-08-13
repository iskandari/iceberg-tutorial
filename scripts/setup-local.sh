#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-icebird}"
REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT="863683271215"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install_with_brew() {
  local package="$1"
  shift
  command -v brew >/dev/null 2>&1 || {
    echo "Install Homebrew first: https://brew.sh" >&2
    exit 1
  }
  brew install "$@" "$package"
}

command -v aws >/dev/null 2>&1 || install_with_brew awscli
command -v Rscript >/dev/null 2>&1 || install_with_brew r
command -v session-manager-plugin >/dev/null 2>&1 || \
  install_with_brew session-manager-plugin --cask

if ! account="$(aws --profile "$PROFILE" --region "$REGION" sts get-caller-identity \
  --query Account --output text 2>/dev/null)"; then
  echo "Configure the supplied credentials as profile '$PROFILE'."
  aws configure --profile "$PROFILE"
  account="$(aws --profile "$PROFILE" --region "$REGION" sts get-caller-identity \
    --query Account --output text)"
fi

[[ "$account" == "$EXPECTED_ACCOUNT" ]] || {
  echo "Profile '$PROFILE' points to AWS account $account, expected $EXPECTED_ACCOUNT." >&2
  exit 1
}

Rscript "$ROOT_DIR/scripts/install-r-packages.R"

echo
echo "Setup complete. Connect with:"
echo "  ./scripts/tunnel-livy.sh"

