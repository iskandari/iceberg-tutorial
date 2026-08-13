#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-icebird-tutorial}"
REGION="${AWS_REGION:-us-east-1}"
LIVY_LOCAL_PORT="${LIVY_LOCAL_PORT:-8998}"
YARN_LOCAL_PORT="${YARN_LOCAL_PORT:-8088}"
SPARK_UI_LOCAL_PORT="${SPARK_UI_LOCAL_PORT:-20888}"
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
primary_ip="$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-instances \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

echo "Opening Spark/YARN UI at http://localhost:$YARN_LOCAL_PORT"
aws --profile "$PROFILE" --region "$REGION" ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$primary_ip\"],\"portNumber\":[\"8088\"],\"localPortNumber\":[\"$YARN_LOCAL_PORT\"]}" &
ui_tunnel_pid=$!

echo "Opening Spark ApplicationMaster proxy at http://localhost:$SPARK_UI_LOCAL_PORT"
aws --profile "$PROFILE" --region "$REGION" ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$primary_ip\"],\"portNumber\":[\"20888\"],\"localPortNumber\":[\"$SPARK_UI_LOCAL_PORT\"]}" &
spark_ui_tunnel_pid=$!

cleanup() {
  kill "$ui_tunnel_pid" 2>/dev/null || true
  kill "$spark_ui_tunnel_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Opening Livy for RStudio at http://localhost:$LIVY_LOCAL_PORT"
echo "After connecting, run ./scripts/list-jobs.sh for working Spark UI links."
aws --profile "$PROFILE" --region "$REGION" ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"8998\"],\"localPortNumber\":[\"$LIVY_LOCAL_PORT\"]}"
