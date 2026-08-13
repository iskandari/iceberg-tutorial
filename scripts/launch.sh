#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-sso-admin}"
REGION="${AWS_REGION:-us-east-1}"
SUBNET_ID="${SUBNET_ID:-subnet-22a44b79}"
EXPECTED_ACCOUNT="863683271215"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

account="$(aws --profile "$PROFILE" --region "$REGION" sts get-caller-identity --query Account --output text)"
[[ "$account" == "$EXPECTED_ACCOUNT" ]] || { echo "Wrong AWS account: $account" >&2; exit 1; }

aws --profile "$PROFILE" --region "$REGION" iam attach-role-policy \
  --role-name EMR_EC2_DefaultRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

cluster_id="$(aws --profile "$PROFILE" --region "$REGION" emr create-cluster \
  --name vpts-iceberg-r-tutorial \
  --release-label emr-7.12.0 \
  --applications Name=Hadoop Name=Spark Name=Livy Name=JupyterEnterpriseGateway \
  --service-role EMR_DefaultRole \
  --ec2-attributes "InstanceProfile=EMR_EC2_DefaultRole,SubnetId=$SUBNET_ID" \
  --instance-groups "file://$ROOT_DIR/config/instance-groups.json" \
  --configurations "file://$ROOT_DIR/config/emr-configurations.json" \
  --auto-termination-policy IdleTimeout=14400 \
  --tags Project=VPTS-Tutorial Owner=Radar \
  --query ClusterId --output text)"

printf '%s\n' "$cluster_id" > "$ROOT_DIR/.cluster-id"
echo "Created $cluster_id"
echo "Wait: aws --profile $PROFILE --region $REGION emr wait cluster-running --cluster-id $cluster_id"

