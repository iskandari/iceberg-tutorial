#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-icebird-tutorial}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_ID="${1:-}"

if [[ -z "$CLUSTER_ID" ]]; then
  CLUSTER_ID="$(aws --profile "$PROFILE" --region "$REGION" emr list-clusters \
    --active --query "reverse(sort_by(Clusters[?Name=='vpts-iceberg-r-tutorial'], &Status.Timeline.CreationDateTime))[0].Id" \
    --output text)"
fi

[[ -n "$CLUSTER_ID" && "$CLUSTER_ID" != "None" ]] || {
  echo "No active vpts-iceberg-r-tutorial cluster found." >&2
  exit 1
}

instance_id="$(aws --profile "$PROFILE" --region "$REGION" emr list-instances \
  --cluster-id "$CLUSTER_ID" --instance-group-types MASTER \
  --query 'Instances[0].Ec2InstanceId' --output text)"
primary_ip="$(aws --profile "$PROFILE" --region "$REGION" ec2 describe-instances \
  --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"

echo "Opening YARN/Spark UI for $CLUSTER_ID at http://localhost:8088"
aws --profile "$PROFILE" --region "$REGION" ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$primary_ip\"],\"portNumber\":[\"8088\"],\"localPortNumber\":[\"8088\"]}"
