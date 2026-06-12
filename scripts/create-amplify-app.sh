#!/usr/bin/env bash
#
# create-amplify-app.sh
# Interactively create a new Amplify Gen 2 (Next.js SSR) app in a TMR corp account
# via the CLI — bypassing the AWS console "Save and Deploy" flow, which re-bootstraps
# CDKToolkit and fails against the TMR-custom bootstrap params:
#   "Parameters: [LevelTwoBoundary, LevelThreeBoundary] do not exist in the template".
#
# Prompts for: app name, GitHub repo, branch, GitHub PAT (hidden).
# Derives: account + region from the AWS profile.
# Fixed:   permission boundary = tmr-boundary-level3, platform = WEB_COMPUTE.
#
# Each app gets its OWN service role: amplify-<appId>-deploy-role, bounded by
# tmr-boundary-level3 and trust-pinned to that specific app's ARN.
#
# Usage:
#   export AWS_PROFILE=tau-b2032-dev      # optional; prompted if unset
#   ./scripts/create-amplify-app.sh
#
# Run from the repo root. The branch you choose MUST already exist in the GitHub repo.

set -euo pipefail

BOUNDARY_NAME="tmr-boundary-level3"        # fixed by TMR governance
PLATFORM="WEB_COMPUTE"                      # Next.js SSR
DEFAULT_REPO="https://github.com/bhanguyen/deploy-amplify-app-corp-acc"
SHARED_AUTH_STACK="tau-b2032-shared-cognito"   # shared Cognito (referenceAuth)

# ---------- AWS profile (derives account + region) ----------
if [[ -z "${AWS_PROFILE:-}" ]]; then
  read -rp "AWS profile [tau-b2032-dev]: " AWS_PROFILE
  AWS_PROFILE="${AWS_PROFILE:-tau-b2032-dev}"
fi
export AWS_PROFILE

REGION="$(aws configure get region 2>/dev/null || true)"
REGION="${REGION:-${AWS_REGION:-ap-southeast-2}}"
export AWS_REGION="$REGION"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || {
  echo "ERROR: cannot resolve AWS identity for profile '$AWS_PROFILE' (SSO login expired?)." >&2
  exit 1
}
BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BOUNDARY_NAME}"

# ---------- Interactive inputs ----------
read -rp "App name: " APP_NAME
[[ -n "$APP_NAME" ]] || { echo "ERROR: app name is required." >&2; exit 1; }

read -rp "GitHub repo URL [${DEFAULT_REPO}]: " REPO_URL
REPO_URL="${REPO_URL:-$DEFAULT_REPO}"
[[ "$REPO_URL" =~ ^https://github\.com/ ]] || echo "WARN: repo URL doesn't look like https://github.com/... continuing anyway."

read -rp "Branch [main]: " BRANCH
BRANCH="${BRANCH:-main}"

read -rsp "GitHub PAT (hidden; scopes: repo + admin:repo_hook): " GITHUB_ACCESS_TOKEN; echo
[[ -n "$GITHUB_ACCESS_TOKEN" ]] || { echo "ERROR: GitHub PAT is required." >&2; exit 1; }

# ---------- Preflight ----------
echo ">> Checking permission boundary exists: $BOUNDARY_ARN"
aws iam get-policy --policy-arn "$BOUNDARY_ARN" >/dev/null 2>&1 || {
  echo "ERROR: boundary policy $BOUNDARY_NAME not found in account $ACCOUNT_ID." >&2
  exit 1
}
echo ">> Checking account is CDK-bootstrapped (cdk-hnb659fds-deploy-role)"
aws iam get-role --role-name "cdk-hnb659fds-deploy-role-${ACCOUNT_ID}-${REGION}" >/dev/null 2>&1 || {
  echo "ERROR: CDK bootstrap role not found — account/region not bootstrapped with qualifier hnb659fds." >&2
  exit 1
}

# ---------- Shared Cognito outputs (referenceAuth needs these as build env vars) ----------
echo ">> Reading shared Cognito outputs from stack '$SHARED_AUTH_STACK'"
get_out() {
  aws cloudformation describe-stacks --stack-name "$SHARED_AUTH_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text 2>/dev/null
}
SHARED_USER_POOL_ID="$(get_out UserPoolId)"
SHARED_USER_POOL_CLIENT_ID="$(get_out UserPoolClientId)"
SHARED_IDENTITY_POOL_ID="$(get_out IdentityPoolId)"
SHARED_AUTH_ROLE_ARN="$(get_out AuthRoleArn)"
SHARED_UNAUTH_ROLE_ARN="$(get_out UnauthRoleArn)"
for v in SHARED_USER_POOL_ID SHARED_USER_POOL_CLIENT_ID SHARED_IDENTITY_POOL_ID SHARED_AUTH_ROLE_ARN SHARED_UNAUTH_ROLE_ARN; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || {
    echo "ERROR: shared auth stack '$SHARED_AUTH_STACK' is missing output for $v." >&2
    echo "       Deploy infra/shared-cognito.yaml first." >&2
    exit 1
  }
done

# ---------- Confirm ----------
cat <<SUMMARY

  App name : $APP_NAME
  Repo     : $REPO_URL
  Branch   : $BRANCH   (must already exist in the repo)
  Account  : $ACCOUNT_ID
  Region   : $REGION
  Platform : $PLATFORM
  Boundary : $BOUNDARY_NAME
  Auth     : shared pool $SHARED_USER_POOL_ID (referenceAuth)
SUMMARY
read -rp "Proceed? [y/N]: " OK
[[ "$OK" == "y" || "$OK" == "Y" ]] || { echo "Aborted."; exit 0; }

# ---------- 1. Create the app (build spec comes from the repo's amplify.yml) ----------
echo ">> Creating app '$APP_NAME' ..."
APP_ID="$(aws amplify create-app \
  --name "$APP_NAME" \
  --platform "$PLATFORM" \
  --repository "$REPO_URL" \
  --access-token "$GITHUB_ACCESS_TOKEN" \
  --environment-variables "SHARED_USER_POOL_ID=${SHARED_USER_POOL_ID},SHARED_USER_POOL_CLIENT_ID=${SHARED_USER_POOL_CLIENT_ID},SHARED_IDENTITY_POOL_ID=${SHARED_IDENTITY_POOL_ID},SHARED_AUTH_ROLE_ARN=${SHARED_AUTH_ROLE_ARN},SHARED_UNAUTH_ROLE_ARN=${SHARED_UNAUTH_ROLE_ARN}" \
  --query "app.appId" --output text)"
echo ">> App created: $APP_ID"

# ---------- 2. Per-app service role (boundary + trust pinned to this app) ----------
ROLE="amplify-${APP_ID}-deploy-role"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}"
echo ">> Creating service role $ROLE ..."

TRUST="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "amplify.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
      "ArnLike": { "aws:SourceArn": "arn:aws:amplify:${REGION}:${ACCOUNT_ID}:apps/${APP_ID}/*" }
    }
  }]
}
JSON
)"

GLUE="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AssumeCdkBootstrapRoles", "Effect": "Allow", "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/cdk-hnb659fds-*" },
    { "Sid": "CdkBootstrapVersion", "Effect": "Allow", "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:*:*:parameter/cdk-bootstrap/*" },
    { "Sid": "CfnAmplifyAndCdk", "Effect": "Allow",
      "Action": [
        "cloudformation:CreateChangeSet", "cloudformation:DeleteChangeSet", "cloudformation:DescribeChangeSet",
        "cloudformation:ExecuteChangeSet", "cloudformation:CreateStack", "cloudformation:UpdateStack",
        "cloudformation:DeleteStack", "cloudformation:DescribeStacks", "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResource", "cloudformation:DescribeStackResources", "cloudformation:GetTemplate",
        "cloudformation:GetTemplateSummary", "cloudformation:ListStackResources", "cloudformation:ListStacks"
      ],
      "Resource": [
        "arn:aws:cloudformation:*:*:stack/amplify-*/*",
        "arn:aws:cloudformation:*:*:stack/CDKToolkit/*"
      ] }
  ]
}
JSON
)"

aws iam create-role \
  --role-name "$ROLE" \
  --assume-role-policy-document "$TRUST" \
  --permissions-boundary "$BOUNDARY_ARN" \
  --description "Amplify Gen2 backend deploy role for app ${APP_ID}" \
  --tags Key=managed-by,Value=create-amplify-app-script Key=app-id,Value="$APP_ID" >/dev/null

aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess-Amplify

aws iam put-role-policy --role-name "$ROLE" \
  --policy-name amplify-gen2-cdk-deploy-glue \
  --policy-document "$GLUE"
echo ">> Role ready: $ROLE_ARN"

# IAM is eventually consistent; let the role/policies propagate before Amplify assumes it.
sleep 10

# ---------- 3. Attach role to app ----------
aws amplify update-app --app-id "$APP_ID" --iam-service-role-arn "$ROLE_ARN" >/dev/null
echo ">> Role attached to app"

# ---------- 4. Create branch (auto-build on) ----------
aws amplify create-branch --app-id "$APP_ID" --branch-name "$BRANCH" --enable-auto-build >/dev/null
echo ">> Branch '$BRANCH' created (auto-build enabled)"

# ---------- 5. Start first build ----------
JOB="$(aws amplify start-job --app-id "$APP_ID" --branch-name "$BRANCH" --job-type RELEASE \
  --query "jobSummary.jobId" --output text)"
echo ">> Build started: job #$JOB"
echo
echo "Console:  https://${REGION}.console.aws.amazon.com/amplify/apps/${APP_ID}"
echo "Live URL: https://${BRANCH}.${APP_ID}.amplifyapp.com   (after the build succeeds)"
