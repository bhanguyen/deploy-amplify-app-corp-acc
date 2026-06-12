# referenceAuth Deploy Failure — Forensic Trace (Option 2)

Trace of the `referenceauth-clean` deploy onto app `d6rrg0udemsrn` (branch backend
stack `amplify-d6rrg0udemsrn-referenceauthclean-branch-e7fd9ff82e`). Reconstructed
from the retained CloudFormation templates + events of the (now-deleted) stacks.

**TL;DR:** Exactly **one** IAM role in the whole backend was created without the
`tmr-boundary-level3` permissions boundary — the S3 **auto-delete** provider role.
The TMR `cfn-exec-role` may only create roles that carry level3, so it was denied and
the stack rolled back. The cause is a known CDK quirk and the fix is **one line** in
`amplify/backend.ts`. This is **not** a platform-team blocker.

> ✅ **VALIDATED 2026-06-12** — with the broadened Aspect (below), referenceAuth deploys
> clean under the TMR boundary (build SUCCEED, site HTTP 200, no new Cognito pool created).

## Stack hierarchy (CDK nested stacks)

```
amplify-…-branch-e7fd9ff82e                 (root / branch stack)
├── auth179371D7                             (auth — referenceAuth)
└── data7552DF31                             (data — AppSync API)   ← FAILED HERE
    ├── amplifyDataTodoNestedStack…          (Todo model)
    └── amplifyDataAmplifyTableManagerNestedStack… (managed-table provider)
```

## Resource map & purpose

### Root stack — branch wiring
| Resource | Purpose |
|----------|---------|
| `Custom::AmplifyBranchLinkerResource` + 2 Lambda + 2 Role + 2 Policy | Links the deployed backend to the Amplify branch and emits `amplify_outputs.json` |
| 2× `AWS::CloudFormation::Stack` | Nested `auth` + `data` stacks |

### Auth stack — referenceAuth (no pool created ✅)
| Resource | Purpose |
|----------|---------|
| `Custom::AmplifyRefAuth` + 2 Lambda + 2 Role + 2 Policy | Custom resource that **reads the shared Cognito pool's config** (from env IDs) and feeds it into outputs. **No `AWS::Cognito::UserPool`** — it references `tau-b2032-shared-cognito`. |

### Data stack — AppSync API (failure site)
| Resource | Purpose |
|----------|---------|
| `AWS::AppSync::GraphQLApi` + `GraphQLSchema` + `ApiKey` + `DataSource` | The GraphQL API (apiKey auth) |
| 2× `AWS::S3::Bucket` + `BucketPolicy` | Codegen-assets bucket + model-introspection-schema bucket |
| 2× `Custom::CDKBucketDeployment` (+ Lambda + LayerVersion + **Role ✅**) | Uploads assets into those buckets |
| 2× `Custom::S3AutoDeleteObjects` (+ **Role ❌**) | Empties the buckets on stack delete |
| 4× `AWS::SSM::Parameter` | Stores data config (schema, API id, etc.) |
| 2× nested `AWS::CloudFormation::Stack` | Todo + TableManager |

### Todo nested stack — the model
| Resource | Purpose |
|----------|---------|
| `Custom::AmplifyDynamoDBTable` | The Amplify-managed DynamoDB table for `Todo` |
| 26× `FunctionConfiguration` + 8× `Resolver` + `DataSource` + **Role ✅** | AppSync pipeline resolvers for Todo CRUD |

### TableManager nested stack — managed-table provider
| Resource | Purpose |
|----------|---------|
| 2× Lambda (`isComplete`/`onEvent`) + `StateMachine` + 3× **Role ✅** + 2× Policy | Orchestrates create/update of Amplify-managed DynamoDB tables |

## Boundary status of every IAM role (from the synthesized templates)

| Stack | Role | `PermissionsBoundary`? |
|-------|------|------------------------|
| root | `AmplifyBranchLinkerCustomResourceLambdaServiceRole` | ✅ level3 |
| root | `AmplifyBranchLinkerCustomResourceProviderframeworkonEventServiceRole` | ✅ level3 |
| auth | `AmplifyRefAuthCustomResourceProviderLambdaServiceRole` | ✅ level3 |
| auth | `AmplifyRefAuthCustomResourceProviderframeworkonEventServiceRole` | ✅ level3 |
| data | `CustomCDKBucketDeployment…ServiceRole` | ✅ level3 |
| **data** | **`CustomS3AutoDeleteObjectsCustomResourceProviderRole`** | ❌ **none** |
| todo | `TodoIAMRole` | ✅ level3 |
| tablemgr | `AmplifyManagedTableIsCompleteRole` / `OnEventRole` / `WaiterStateMachineRole` | ✅ level3 |

**8 of 9 roles got the boundary** (from the `backend.ts` Aspect). Only the auto-delete
provider role missed it.

## What failed and why

CloudFormation event (data stack, 10:47:18 PM):
```
CREATE_FAILED  AWS::IAM::Role  CustomS3AutoDeleteObjectsCustomResourceProviderRole…
User: …/cdk-hnb659fds-cfn-exec-role-… is not authorized to perform: iam:CreateRole
on …/amplify-d6rrg0udemsrn-ref-CustomS3AutoDeleteObjects-… because no permissions
boundary allows the iam:CreateRole action  (HandlerErrorCode: UnauthorizedTaggingOperation)
```

**Chain of causation:**
1. The TMR `cfn-exec-role` is bounded by `tmr-boundary-level2`, whose
   `CreateOrChangeOnlyWithBoundary` allows `iam:CreateRole` **only if** the new role's
   `iam:PermissionsBoundary == tmr-boundary-level3`.
2. The auto-delete role was synthesized **without** any boundary → condition not met → `CreateRole` denied (403).
3. Data stack → `CREATE_FAILED` → root stack → `ROLLBACK`. Rollback then couldn't delete
   the (now non-empty) asset buckets → `DELETE_FAILED` (the cleanup mess we saw).

**Why this one role had no boundary** (the actual bug):
- It is created by CDK's low-level **`CustomResourceProvider`** (used by S3
  `autoDeleteObjects: true`), which emits the role as a **raw `CfnResource`** of type
  `AWS::IAM::Role` — *not* an `iam.Role` / `CfnRole` construct.
- cdk.json's `@aws-cdk/core:permissionsBoundary` **does not apply** to `CustomResourceProvider` roles (documented CDK limitation).
- Our `backend.ts` Aspect used `node instanceof CfnRole`, which is **false** for that raw
  `CfnResource` → the Aspect skipped it. Hence: every normal role got level3, this one didn't.

## What can be done

### ✅ Recommended — one-line Aspect fix (no platform-team needed)
Broaden the Aspect to match **any** `CfnResource` of type `AWS::IAM::Role`, not just `CfnRole`:

```ts
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
This catches the `CustomResourceProvider` role too. With all 9 roles carrying level3, the
deploy should clear the `cfn-exec-role` gate. (Deploy onto a **fresh** branch — the prior
attempt's stack must be fully gone first.)

### Alternative — avoid the construct
The auto-delete role exists only because the asset buckets use `autoDeleteObjects: true`.
That is internal to Amplify's data construct and not configurable from `defineData`, so
this isn't a practical lever here — the Aspect fix is the right path.

### Platform-team levers (only if the Aspect fix somehow doesn't hold)
- Drop the boundary on the bootstrap `cfn-exec-role` (`InputPermissionsBoundary=''`) — security downgrade.
- Relax `tmr-boundary-level2`'s `CreateOrChangeOnlyWithBoundary` for `amplify-*` roles.

## Outcome
- ✅ The Aspect fix was **validated** on a clean deploy (branch `referenceauth-v2`,
  app `d6rrg0udemsrn`): all 9 roles carried level3, deploy SUCCEEDED, no new pool created.
  No other `CustomResourceProvider` role surfaced.
- Frontend-only (Option 1) remains a simpler fallback when the data layer doesn't need
  Cognito-backed authz.
