#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-icebird}"
REGION="${AWS_REGION:-us-east-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_ID="${1:-}"

if [[ -z "$CLUSTER_ID" && -f "$ROOT_DIR/.cluster-id" ]]; then
  CLUSTER_ID="$(<"$ROOT_DIR/.cluster-id")"
fi

if [[ -z "$CLUSTER_ID" ]]; then
  CLUSTER_ID="$(aws --profile "$PROFILE" --region "$REGION" emr list-clusters \
    --active --query "reverse(sort_by(Clusters[?Name=='vpts-iceberg-r-tutorial'], &Status.Timeline.CreationDateTime))[0].Id" \
    --output text)"
fi

[[ -n "$CLUSTER_ID" && "$CLUSTER_ID" != "None" ]] || {
  echo "No active vpts-iceberg-r-tutorial cluster found." >&2
  exit 1
}

echo "Connecting to $CLUSTER_ID"

instance_id="$(aws --profile "$PROFILE" --region "$REGION" emr list-instances \
  --cluster-id "$CLUSTER_ID" --instance-group-types MASTER \
  --query 'Instances[0].Ec2InstanceId' --output text)"

aws --profile "$PROFILE" --region "$REGION" ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8998"],"localPortNumber":["8998"]}'
