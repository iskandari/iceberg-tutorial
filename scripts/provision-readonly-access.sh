#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AWS_PROFILE:-sso-admin}"
REGION="${AWS_REGION:-us-east-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="icebird-tutorial"
ROLE_NAME="EMR_EC2_VPTS_Tutorial_ReadOnlyRole"

aws --profile "$PROFILE" --region "$REGION" iam get-user \
  --user-name "$USER_NAME" >/dev/null 2>&1 || \
  aws --profile "$PROFILE" --region "$REGION" iam create-user \
    --user-name "$USER_NAME" >/dev/null

aws --profile "$PROFILE" --region "$REGION" iam put-user-policy \
  --user-name "$USER_NAME" \
  --policy-name VPTSClusterSSMAccess \
  --policy-document "file://$ROOT_DIR/config/colleague-ssm-policy.json"

aws --profile "$PROFILE" --region "$REGION" iam get-role \
  --role-name "$ROLE_NAME" >/dev/null 2>&1 || \
  aws --profile "$PROFILE" --region "$REGION" iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$ROOT_DIR/config/emr-ec2-trust-policy.json" >/dev/null

aws --profile "$PROFILE" --region "$REGION" iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role
aws --profile "$PROFILE" --region "$REGION" iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws --profile "$PROFILE" --region "$REGION" iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name DenyVPTSDataMutations \
  --policy-document "file://$ROOT_DIR/config/read-only-deny-policy.json"

aws --profile "$PROFILE" --region "$REGION" iam get-instance-profile \
  --instance-profile-name "$ROLE_NAME" >/dev/null 2>&1 || \
  aws --profile "$PROFILE" --region "$REGION" iam create-instance-profile \
    --instance-profile-name "$ROLE_NAME" >/dev/null

if ! aws --profile "$PROFILE" --region "$REGION" iam get-instance-profile \
  --instance-profile-name "$ROLE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' --output text | grep -qw "$ROLE_NAME"; then
  aws --profile "$PROFILE" --region "$REGION" iam add-role-to-instance-profile \
    --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
fi

echo "Provisioned IAM user: $USER_NAME"
echo "Provisioned read-only EMR instance profile: $ROLE_NAME"

