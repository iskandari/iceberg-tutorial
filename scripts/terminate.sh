#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-sso-admin}"
REGION="${AWS_REGION:-us-east-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_ID="${1:-$(<"$ROOT_DIR/.cluster-id")}"

aws --profile "$PROFILE" --region "$REGION" emr terminate-clusters --cluster-ids "$CLUSTER_ID"
echo "Terminating $CLUSTER_ID"

