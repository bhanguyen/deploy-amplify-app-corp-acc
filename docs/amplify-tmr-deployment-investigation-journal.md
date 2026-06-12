# Amplify Gen 2 on the TMR Corp Account — Deployment Investigation Journal

A full account of every deployment failure we hit standing up AWS Amplify Gen 2
(Next.js SSR + Cognito + AppSync) in the TMR account `471112770810`, how we
investigated each one, the true root cause, and the fix. Ends with a step-by-step
playbook so new apps can be built and deployed here with confidence.

- **Account / region:** `471112770810` / `ap-southeast-2`
- **CLI profile:** `tau-b2032-dev` (SSO role `tmr-developer`); console login is `tmr-account-admin`
- **App framework:** Next.js 14 (App Router, SSR) + Amplify Gen 2 (`auth` + `data`)
- **Test app used throughout:** `d6rrg0udemsrn` (deploy-amplify-app-test)

---

## 0. The environment that makes this hard

TMR enforces **IAM permission boundaries** on every role. Two matter:

- **`tmr-boundary-level2`** — broad-allow, but with a critical rule
  (`CreateOrChangeOnlyWithBoundary`): a principal bounded by level2 may call
  `iam:CreateRole` **only if the new role's `iam:PermissionsBoundary` is exactly
  `tmr-boundary-level3`**.
- **`tmr-boundary-level3`** — IAM restricted to `Get*/List*/PassRole` only.

The CDK **bootstrap** (`CDKToolkit`, qualifier `hnb659fds`) was deployed from a
**TMR-custom template** (`cdktoolkit-tmr-template.yml`) which:
- gives the **`cfn-exec-role`** identity policy `AdministratorAccess` **but** boundary
  `tmr-boundary-level2` (param `InputPermissionsBoundary`);
- adds extra params `LevelTwoBoundary` / `LevelThreeBoundary` used to boundary-stamp the
  bootstrap roles.

**Consequence that drove almost every failure:** during a backend deploy, the
`cfn-exec-role` creates the app's IAM roles — and it can only create a role if that role
**already carries `tmr-boundary-level3`**. Any role synthesized without it → `AccessDenied`.

---

## 1. Issue — Build fails during the build stage (`ampx generate outputs`)

### Symptom
Amplify builds failed almost every time. Build log:
```
AccessDeniedError: Unable to get backend outputs due to insufficient permissions.
... not authorized to perform: cloudformation:GetTemplateSummary
... assumed-role/AemiliaControlPlaneLambda-CodeBuildRole-... (account 711974673587)
```
The failing command was the `backend` phase of `amplify.yml`:
`npx ampx generate outputs --branch $AWS_BRANCH --app-id $AWS_APP_ID`.

### How we investigated
- `aws amplify get-app` → **`iamServiceRoleArn: null`**.
- `aws cloudformation describe-stacks --stack-name amplify-<appId>-<branch>-...` → **does not exist**.
- The principal in the error is `…711974673587:…CodeBuildRole` — i.e. **AWS Amplify's own
  managed build account** ("Aemilia" is AWS's internal codename for Amplify), not ours.

### Root cause (two compounding)
1. **No backend stack had ever been deployed** — so there were no outputs to "generate".
2. **No IAM service role on the app** — so the build ran as AWS's managed CodeBuild role,
   which has **zero** permission in our account → `GetTemplateSummary` denied.

### Fix
1. **Create a per-app IAM service role** (`amplify-<appId>-deploy-role`):
   trust `amplify.amazonaws.com` (pinned to the app via `aws:SourceArn`), boundary
   `tmr-boundary-level3`, managed policy `AdministratorAccess-Amplify` **plus** an inline
   policy granting `sts:AssumeRole` on `cdk-hnb659fds-*` + CloudFormation/SSM (the Gen-2
   managed policy `AmplifyBackendDeployFullAccess` is not available in this account).
   Attach via `aws amplify update-app --iam-service-role-arn`.
2. **Switch `amplify.yml`** backend phase from `ampx generate outputs` to
   **`npx ampx pipeline-deploy --branch $AWS_BRANCH --app-id $AWS_APP_ID`** — this deploys
   the backend *and* emits `amplify_outputs.json` in one build.
3. **Set platform `WEB_COMPUTE`** (was `WEB`). An SSR Next.js build serves nothing as a
   static site → root returned **HTTP 404** until this was fixed.

Result: backend (Cognito/AppSync/DynamoDB) deployed, frontend served HTTP 200.

### Note on the boundary
Do **not** pass `--parameters LevelTwoBoundary/LevelThreeBoundary` to `pipeline-deploy` —
the app/backend templates don't declare them (`Parameters … do not exist in the template`).
The boundary is applied at synth via `cdk.json` + a `backend.ts` Aspect, not via params.

---

## 2. Issue — The AWS console cannot create an app (`LevelTwo/ThreeBoundary do not exist`)

### Symptom
Creating a new app in the **Amplify console** failed instantly on "Save and Deploy":
```
Build failed — Parameters: [LevelTwoBoundary, LevelThreeBoundary] do not exist in the template
```
The app was never persisted.

### How we investigated
- CloudTrail (`aws cloudtrail lookup-events`): the failing call was **`UpdateStack`**, run by
  **`tmr-account-admin`** with a **Safari user-agent** → it came from the **browser/console**,
  not the build.
- `aws cloudformation describe-stacks --stack-name CDKToolkit` → the bootstrap carries params
  `LevelTwoBoundary=tmr-boundary-level2`, `LevelThreeBoundary=tmr-boundary-level3`.

### Root cause
The Amplify Gen 2 console runs a **CDK bootstrap step** on app creation — an `UpdateStack`
on `CDKToolkit` using the **standard** CDK template, which doesn't declare the TMR-custom
`LevelTwo/ThreeBoundary` params → CloudFormation rejects it. It is *not* our repo, build, or
code. CLI deploys are unaffected because `ampx pipeline-deploy` **never re-bootstraps**.

### Fix
**Create apps via CLI, never the console.** We wrote
[`scripts/create-amplify-app.sh`](../scripts/create-amplify-app.sh) (interactive: app name,
repo, branch, hidden GitHub PAT; derives account/region from the profile; mints the per-app
service role). It never touches the bootstrap, so it sidesteps this entirely.

---

## 3. Issue — One shared Cognito user pool across apps

By default `defineAuth` provisions a **new** Cognito pool per app/branch. Goal: all apps
share **one** pool we create and manage. This was the hardest thread.

### 3a. The shared pool (works)
Deployed a small CloudFormation stack
[`infra/shared-cognito.yaml`](../infra/shared-cognito.yaml) →
`tau-b2032-shared-cognito`: user pool `ap-southeast-2_i20meZSe3`, an app client, an identity
pool, and authenticated/unauthenticated IAM roles (each boundary-stamped `tmr-boundary-level3`).
It deployed clean — proving our `tmr-developer` profile *can* create roles when they carry the
boundary.

### 3b. Two ways to consume it

| | Option 1 — frontend-only | Option 2 — referenceAuth (backend) |
|---|---|---|
| Backend | `defineBackend({ data })` (no Cognito) | `defineBackend({ auth: referenceAuth(...), data })` |
| Frontend | `Amplify.configure({...outputs, auth:{...}})` from `NEXT_PUBLIC_*` env | uses generated `amplify_outputs.json` |
| Data ↔ Cognito authz | not integrated (data stays apiKey) | integrated (can use `allow.authenticated()`) |
| Status | ✅ validated | ✅ validated (after the fix below) |

### 3c. The referenceAuth failure chain (and each fix)

`referenceAuth` requires bumping `@aws-amplify/backend` to **≥ 1.7** (we used 1.23). That bump
surfaced several issues in sequence:

1. **`npm ci` lockfile desync** — `npm error Missing: @smithy/core… from lock file`.
   An in-place `npm install` left `package-lock.json` inconsistent. **Fix:** delete the
   lockfile and `npm install` to regenerate cleanly; validate with `npm ci`.
2. **`@parcel/watcher` Linux binary missing** — `No prebuild or local build of
   @parcel/watcher found. Tried @parcel/watcher-linux-x64-glibc`. The newer `ampx` requires
   `@parcel/watcher`; a **macOS-generated lockfile omits the Linux native binary**.
   **Fix:** in `amplify.yml`, after `npm ci`, run
   `npm install @parcel/watcher-linux-x64-glibc@$(node -p "require('@parcel/watcher/package.json').version") --no-save`.
   (Also dropped `node_modules` from the build cache to avoid masking missing optional deps.)
3. **`Cannot find module './auth/resource'`** during `next build` — a stray tracked
   `archived/backend.ts` (with a broken relative import) was being type-checked repo-wide.
   **Fix:** add `archived` to `tsconfig.json` `exclude`. (This was a latent repo-wide bug.)
4. **`iam:CreateRole … no permissions boundary allows the iam:CreateRole action`** — the real
   blocker. The backend deploy created a role *without* `tmr-boundary-level3`, which the
   `cfn-exec-role` (level2) refuses. This persisted even after adding a boundary Aspect.

### 3d. The forensic trace that cracked it

The early failures were confounded by **rollback churn** (a failed create leaves stacks in
`ROLLBACK_FAILED` with non-empty S3 buckets, which then block the next deploy). So we did a
clean deploy, let it fail, and then traced the **actual synthesized templates**:

1. `aws cloudformation list-stacks --stack-status-filter DELETE_COMPLETE` → got the **ARNs**
   of all 5 (now-deleted) nested stacks (CloudFormation retains deleted-stack templates by ARN).
2. `aws cloudformation get-template --stack-name <ARN>` for each → parsed every
   `AWS::IAM::Role` and checked for a `PermissionsBoundary` property.

Result — **8 of 9 roles had the boundary; exactly one did not:**

| Stack | Role | Boundary |
|-------|------|----------|
| auth | `AmplifyRefAuthCustomResource…` (referenceAuth's own) | ✅ |
| data | `CustomCDKBucketDeployment…ServiceRole` | ✅ |
| **data** | **`CustomS3AutoDeleteObjectsCustomResourceProviderRole`** | ❌ |
| root/todo/tablemgr | all others | ✅ |

The lone role's properties were just `[AssumeRolePolicyDocument, ManagedPolicyArns]` — no
`PermissionsBoundary`, no `Tags`.

### 3e. Root cause (precise)

`CustomS3AutoDeleteObjects…` is created by CDK's **low-level `CustomResourceProvider`** (the
singleton behind S3 `autoDeleteObjects: true`), which emits its role as a **raw `CfnResource`
of type `AWS::IAM::Role`** — *not* an `iam.Role` / `CfnRole` construct. Therefore:
- `cdk.json`'s `@aws-cdk/core:permissionsBoundary` **skips it** (documented CDK limitation), and
- our `backend.ts` Aspect used `node instanceof CfnRole`, which is **false** for that raw
  resource → it was skipped too.

So that single role was born without the boundary, and `cfn-exec-role` denied its creation.
The `UnauthorizedTaggingOperation` code in the error was a red herring — the real cause is the
missing level3 boundary (verified: `tmr-boundary-level2` allows tagging unconditionally).

### 3f. The fix (one line of logic)

Match the **CloudFormation type**, not the construct class, so *every* role — including
`CustomResourceProvider` ones — is stamped:

```ts
// amplify/backend.ts
import { Aspects, CfnResource, IAspect } from 'aws-cdk-lib';
import { IConstruct } from 'constructs';

class TmrPermissionsBoundary implements IAspect {
  visit(node: IConstruct): void {
    if (CfnResource.isCfnResource(node) && node.cfnResourceType === 'AWS::IAM::Role') {
      node.addPropertyOverride(
        'PermissionsBoundary',
        `arn:aws:iam::${node.stack.account}:policy/tmr-boundary-level3`,
      );
    }
  }
}
Aspects.of(backend.stack).add(new TmrPermissionsBoundary());
```

**Validation:** clean deploy of `referenceAuth` on a fresh branch → **SUCCEED**, site HTTP 200,
Cognito pool count **unchanged** (referenced the shared pool, created none).

---

## 4. Playbook — develop & deploy a new Amplify app here (with confidence)

### Always
- **Create the app via CLI**, never the console (Issue 2): `./scripts/create-amplify-app.sh`.
  It makes the per-app service role + sets `WEB_COMPUTE` + connects the repo.
- **`amplify.yml`** backend phase = `npx ampx pipeline-deploy …` (not `generate outputs`).
- **Keep the boundary Aspect** in `amplify/backend.ts` matching `CfnResource` type
  `AWS::IAM::Role` (Issue 3e) — this is what makes *any* backend deploy pass under the TMR boundary.
- **Keep `cdk.json`** (`@aws-cdk/core:permissionsBoundary` → `tmr-boundary-level3`). The Aspect
  is the backstop; cdk.json covers the rest. Don't remove either.
- **`tsconfig.json`** must `exclude` non-app dirs like `archived` (Issue 3c-3).

### If using the shared Cognito pool
- **Backend (Option 2):** `auth/resource.ts` = `referenceAuth({...process.env.SHARED_*})`;
  bump `@aws-amplify/backend` ≥ 1.16 and `@aws-amplify/backend-cli` ≥ 1.8; regenerate the
  lockfile cleanly; add the `@parcel/watcher` Linux install to `amplify.yml`; set the
  `SHARED_*` env vars on the app.
- **Frontend (Option 1):** simpler — `defineBackend({ data })` and configure the pool in the
  frontend from `NEXT_PUBLIC_SHARED_*` env vars. No dep bump, no boundary concerns.

### Shared pool values (account 471112770810)
```
SHARED_USER_POOL_ID        = ap-southeast-2_i20meZSe3
SHARED_USER_POOL_CLIENT_ID = 6hlpna09q0omla22mvoljd8rq6
SHARED_IDENTITY_POOL_ID    = ap-southeast-2:d7fcbd7b-2086-4abf-97b2-14adee465b55
SHARED_AUTH_ROLE_ARN       = arn:aws:iam::471112770810:role/tau-b2032-shared-authRole
SHARED_UNAUTH_ROLE_ARN     = arn:aws:iam::471112770810:role/tau-b2032-shared-unauthRole
```

---

## 5. Investigation techniques (reusable)

- **Read the build log's principal & account** — `AemiliaControlPlaneLambda…711974673587`
  told us the build ran as AWS's role, not ours.
- **`aws cloudtrail lookup-events`** — identified that a failure came from the *console*
  (browser user-agent), not the build.
- **`get-template` on deleted stacks (by ARN)** — recovered the exact synthesized templates
  after cleanup and let us diff `PermissionsBoundary` per role. This is what pinpointed the
  single offending role.
- **Boundary policy inspection** — `get-policy-version` on `tmr-boundary-level2` revealed the
  exact `CreateOrChangeOnlyWithBoundary` condition (`iam:PermissionsBoundary == level3`).
- **Clean-room reproduction** — always deploy onto a *fresh* branch/stack; rollback cruft
  (non-empty S3 buckets blocking deletion) produces misleading secondary errors.

---

## 6. Operational gotcha — stuck rollbacks

A failed backend create leaves `ROLLBACK_FAILED`/`DELETE_FAILED` stacks because the asset
S3 buckets aren't empty (their auto-delete Lambda never got created). To clean up: empty the
buckets (all object versions + delete markers via `s3api delete-objects`), then
`delete-stack` the root (it cascades), then delete the Amplify + git branches.

---

## Open questions / caveats
- Option 2 confidence is now **proven** on the test app, but it carries more moving parts
  (dep bump + 4 build fixes). Option 1 is simpler if the data layer doesn't need Cognito authz.
- The console-creation limitation (Issue 2) persists until the platform team aligns the
  CDK bootstrap to the standard template; until then, CLI creation is mandatory.
