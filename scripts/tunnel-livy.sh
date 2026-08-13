#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-sso-admin}"
REGION="${AWS_REGION:-us-east-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_ID="${1:-$(<"$ROOT_DIR/.cluster-id")}"

instance_id="$(aws --profile "$PROFILE" --region "$REGION" emr list-instances \
  --cluster-id "$CLUSTER_ID" --instance-group-types MASTER \
  --query 'Instances[0].Ec2InstanceId' --output text)"

aws --profile "$PROFILE" --region "$REGION" ssm start-session \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8998"],"localPortNumber":["8998"]}'

