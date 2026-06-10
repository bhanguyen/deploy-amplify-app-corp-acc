# Amplify Gen 2 Deployment Runbook — TMR Corp Account

How to deploy this Next.js (SSR) + Amplify Gen 2 app into the TMR corporate AWS
account, the two failure modes we hit, their root causes, and the verified fixes.

## Environment

| Item | Value |
|------|-------|
| AWS account | `471112770810` (TMR) |
| CLI profile | `tau-b2032-dev` (SSO role `tmr-developer`) |
| Console login | SSO role `tmr-account-admin` (different identity from the CLI) |
| Region | `ap-southeast-2` |
| Permission boundary | `tmr-boundary-level3` — mandatory on every IAM role created |
| CDK bootstrap | `CDKToolkit`, qualifier `hnb659fds`, custom TMR template (`cdktoolkit-tmr-template.yml`), version 31 |
| App framework | Next.js 14 (App Router, SSR) + Amplify Gen 2 (`auth` + `data`) |
| Working app | `d2fxhog5vlbh9b` → https://main.d2fxhog5vlbh9b.amplifyapp.com |

Key fact: the Amplify **build** runs in an AWS-managed account (`711974673587`,
"Aemilia" = AWS Amplify's internal service account). With a per-app IAM **service role**
attached, the build operates **as that role** (in `471112770810`) and assumes the CDK
bootstrap roles via the own-account trust — so the cross-account trust to `711974673587`
is not needed. See [CDK bootstrap trust](#cdk-bootstrap-trust-trustedaccounts).

---

## Issue A — Build fails on `ampx generate outputs` (AccessDenied)

### Symptom
Build log:
```
AccessDeniedError: Unable to get backend outputs due to insufficient permissions.
... not authorized to perform: cloudformation:GetTemplateSummary
on .../stack/amplify-d2fxhog5vlbh9b-main-branch-.../*
```

### Root cause (two compounding problems)
1. **No backend stack existed** — the backend was never deployed, so there were no
   outputs to "generate."
2. **The app had no IAM service role** (`iamServiceRoleArn: null`). The build therefore
   ran as the AWS-managed Amplify CodeBuild role in `711974673587`, which has **zero**
   permission in `471112770810` → `GetTemplateSummary` denied.

### Fix — fully-managed Gen 2 flow (backend + frontend in one build)
1. **Create an IAM service role** bounded by `tmr-boundary-level3` (see
   [Service role design](#service-role-design)) and attach it to the app:
   ```
   aws amplify update-app --app-id <APP_ID> --iam-service-role-arn <ROLE_ARN>
   ```
2. **Use `ampx pipeline-deploy`** in `amplify.yml` (not `generate outputs`):
   ```yaml
   backend:
     phases:
       build:
         commands:
           - npm ci --cache .npm --prefer-offline
           - npx ampx pipeline-deploy --branch $AWS_BRANCH --app-id $AWS_APP_ID
   ```
   `pipeline-deploy` provisions the backend (Cognito/AppSync/DynamoDB) **and** emits
   `amplify_outputs.json` for the frontend build, in one deployment.
3. **Set the app platform to `WEB_COMPUTE`** (SSR). With `WEB` (static), the SSR `.next`
   build has no `index.html` at root and the site returns **HTTP 404**:
   ```
   aws amplify update-app --app-id <APP_ID> --platform WEB_COMPUTE
   ```

### Do NOT
- Do **not** pass `--parameters LevelTwoBoundary=... LevelThreeBoundary=...` to
  `ampx pipeline-deploy`. The app/backend templates do not declare those parameters →
  `Parameters: [LevelTwoBoundary, LevelThreeBoundary] do not exist in the template`.
  The boundary is applied by `cdk.json` (see [boundary mechanism](#permission-boundary-mechanism)),
  not by stack parameters.

---

## Issue B — Console "Save and Deploy" fails instantly creating a new app

### Symptom
Creating a new app in the **AWS Amplify console** fails immediately after clicking
"Save and Deploy"; the app is not persisted:
```
Build failed
Parameters: [LevelTwoBoundary, LevelThreeBoundary] do not exist in the template
```
This happens with the standard console flow (no boundary fields, env vars = None).

### Root cause (verified via CloudTrail + CDKToolkit)
The Amplify Gen 2 console runs a **CDK bootstrap step from the browser** — an
`UpdateStack` on the **CDKToolkit** stack (CloudTrail: `UpdateStack`, Safari
user-agent, run as `tmr-account-admin`).

- This account's `CDKToolkit` was bootstrapped with the **TMR-custom template**, which
  **adds** the parameters `LevelTwoBoundary` (=`tmr-boundary-level2`) and
  `LevelThreeBoundary` (=`tmr-boundary-level3`).
- The console updates the bootstrap with the **standard AWS CDK template**, which does
  **not** declare those parameters → CloudFormation `ValidationException`.

It is **not** the repo, the app build, env vars, `cdk.json`, `backend.ts`, or
`amplify.yml`. It is a bootstrap-template mismatch, triggered only by the console UI.

### Why the CLI is unaffected
`ampx pipeline-deploy` (the build) **never re-bootstraps** — it reads the SSM bootstrap
version and uses the existing `cdk-hnb659fds-*` roles. Only the console insists on
updating the bootstrap, which collides with the TMR custom parameters.

### Fix — create new apps via CLI, not the console
Use [`scripts/create-amplify-app.sh`](../scripts/create-amplify-app.sh) (see
[runbook](#runbook-create-a-new-app-via-cli)). It never touches the bootstrap.

### Governance alternative (needs platform-team sign-off)
Re-bootstrap with the **standard** CDK template using the built-in boundary mechanism
(`cdk bootstrap --custom-permissions-boundary tmr-boundary-level3`), dropping the custom
`LevelTwoBoundary`/`LevelThreeBoundary` params. Then the console flow would work. The
bootstrap is a deliberate TMR-governed artifact — do not change it without approval.

---

## Permission boundary mechanism

There are two ways this repo could apply `tmr-boundary-level3` to backend IAM roles.
Only one is needed.

| Mechanism | Scope | Needed? |
|-----------|-------|---------|
| `cdk.json` → `@aws-cdk/core:permissionsBoundary` (by name) | **All** roles, all stacks (auth, data, root, future) | ✅ **Required — keep it** |
| `backend.ts` Aspect (`addPropertyOverride('PermissionsBoundary', …)`) | Only `auth` + `data` stacks | ❌ Redundant — can remove |

**Verified:** even the **root-stack** `AmplifyBranchLinker` roles carry the boundary,
and the Aspect never targets the root stack — so `cdk.json` is the mechanism doing the
work, and it is comprehensive.

### Answer: minimal correct setup
- ✅ **Keep `cdk.json`** exactly as-is (5 lines). Removing it removes the boundary from
  every backend role — a governance violation, and the deploy will likely be **denied**
  if the account enforces boundaries on role creation.
- ✅ **`backend.ts` can be the bare AWS template** (drop the Aspect), because `cdk.json`
  already covers all roles:
  ```ts
  import { defineBackend } from '@aws-amplify/backend';
  import { auth } from './auth/resource.js';
  import { data } from './data/resource.js';

  defineBackend({ auth, data });
  ```
- 🚫 Do **not** drop both `cdk.json` and the Aspect.

`cdk.json` (keep):
```json
{
  "app": "npx ts-node amplify/backend.ts",
  "context": {
    "@aws-cdk/core:permissionsBoundary": { "name": "tmr-boundary-level3" }
  }
}
```

---

## Service role design

One service role **per app**, named `amplify-<appId>-deploy-role`:

- **Trust:** `amplify.amazonaws.com`, pinned to the app via
  `aws:SourceAccount = 471112770810` + `aws:SourceArn = arn:aws:amplify:ap-southeast-2:471112770810:apps/<appId>/*`.
- **Permission boundary:** `tmr-boundary-level3` (mandatory).
- **Managed policy:** `AdministratorAccess-Amplify` (Amplify SDK breadth). Note the
  AWS-managed `AmplifyBackendDeployFullAccess` policy is **not available** in this account.
- **Inline policy `amplify-gen2-cdk-deploy-glue`** (what the Gen 1 managed policy lacks):
  - `sts:AssumeRole` on `arn:aws:iam::471112770810:role/cdk-hnb659fds-*`
  - `ssm:GetParameter` on `arn:aws:ssm:*:*:parameter/cdk-bootstrap/*`
  - CloudFormation read/change-set actions on `stack/amplify-*/*` and `stack/CDKToolkit/*`
    (incl. `GetTemplateSummary`, `ExecuteChangeSet`).

The boundary is broad-allow (`NotAction` on iam/guardduty/org/securityhub) and permits
`sts:AssumeRole`, CloudFormation, SSM, S3 — everything CDK needs. The service role only
assumes the CDK bootstrap roles; the bootstrap `cfn-exec-role` does the actual resource
(and bounded-role) creation.

---

## CDK bootstrap trust (`TrustedAccounts`)

There are two Amplify Gen 2 backend-deploy models:

| Model | How the build reaches the CDK roles | Needs `TrustedAccounts=711974673587`? |
|-------|-------------------------------------|----------------------------------------|
| **A — service role** (standard here) | Build runs **as the app's service role** (in `471112770810`); assumes the CDK roles via the **own-account** trust (`471112770810:root`) | ❌ No |
| **B — no service role** | Amplify's managed build (in `711974673587`) assumes the CDK roles **cross-account** | ✅ Yes |

Every app here uses its own service role (Model A), so the cross-account trust was
**redundant** and was **removed** (2026-06-10) to shrink the trust surface — only
`471112770810` can now assume the `cdk-hnb659fds-*` roles.

Removal was a surgical, single-parameter CloudFormation update on `CDKToolkit` (no
re-bootstrap, no resource replacement) — flip `TrustedAccounts` to empty, reuse all other
params:
```bash
aws cloudformation update-stack --stack-name CDKToolkit \
  --use-previous-template --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=TrustedAccounts,ParameterValue= \
    ParameterKey=Qualifier,UsePreviousValue=true \
    ParameterKey=CloudFormationExecutionPolicies,UsePreviousValue=true \
    ParameterKey=LevelTwoBoundary,UsePreviousValue=true \
    ParameterKey=LevelThreeBoundary,UsePreviousValue=true \
    # ...UsePreviousValue=true for every remaining param
```
It modifies only the trust/policies of the four `cdk-hnb659fds-*` roles, the assets KMS
key, and the staging bucket. Verify a build still deploys afterward (Model A is unaffected).
To re-enable Model B later, set `TrustedAccounts=711974673587` and re-update.

## Runbook: create a new app via CLI

```bash
export AWS_PROFILE=tau-b2032-dev
export GITHUB_ACCESS_TOKEN=ghp_xxx          # GitHub PAT, scopes: repo + admin:repo_hook
cd <repo-root>
./scripts/create-amplify-app.sh <app-name> [branch] [repo-url]
```

The script:
1. `create-app` with `--platform WEB_COMPUTE` (build spec comes from the repo `amplify.yml`).
2. Creates the per-app service role (boundary + trust pinned to the new app id).
3. `update-app --iam-service-role-arn <role>`.
4. `create-branch --enable-auto-build`.
5. `start-job --job-type RELEASE`, then prints the console + live URLs.

It never calls `UpdateStack` on `CDKToolkit`, so it sidesteps Issue B entirely.

---

## Verification

```bash
export AWS_PROFILE=tau-b2032-dev AWS_REGION=ap-southeast-2

# Build status
aws amplify list-jobs --app-id <APP_ID> --branch-name main --max-items 1 \
  --query "jobSummaries[0].status"

# Backend stack created
aws cloudformation describe-stacks \
  --stack-name amplify-<APP_ID>-main-branch-<suffix> \
  --query "Stacks[0].StackStatus"

# Every backend role carries the boundary
for S in $(aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?contains(StackName,'amplify-<APP_ID>')].StackName" --output text); do
  for R in $(aws cloudformation list-stack-resources --stack-name "$S" \
      --query "StackResourceSummaries[?ResourceType=='AWS::IAM::Role'].PhysicalResourceId" --output text); do
    aws iam get-role --role-name "$R" \
      --query "Role.PermissionsBoundary.PermissionsBoundaryArn" --output text
  done
done

# Live site
curl -s -o /dev/null -w "%{http_code}\n" https://main.<APP_ID>.amplifyapp.com   # expect 200
```

---

## Known-good `amplify.yml`

```yaml
version: 1
backend:
  phases:
    build:
      commands:
        - npm ci --cache .npm --prefer-offline
        - npx ampx pipeline-deploy --branch $AWS_BRANCH --app-id $AWS_APP_ID
frontend:
  phases:
    preBuild:
      commands:
        - npm ci --cache .npm --prefer-offline
    build:
      commands:
        - npm run build
  artifacts:
    baseDirectory: .next
    files:
      - '**/*'
  cache:
    paths:
      - .next/cache/**/*
      - .npm/**/*
      - node_modules/**/*
```

---

## Open questions / caveats

- The GitHub-token repo connection in `create-app` was not tested end-to-end (no token
  on hand). If it errors, it is almost always PAT scopes — needs `repo` + `admin:repo_hook`.
- Whether an Organizations **SCP** hard-enforces the boundary on `iam:CreateRole` could
  not be confirmed from a member account. Regardless, keep `cdk.json` so backend roles
  are always bounded.
- The console-vs-CLI conflict (Issue B) persists until the bootstrap is realigned to the
  standard template (governance decision).
