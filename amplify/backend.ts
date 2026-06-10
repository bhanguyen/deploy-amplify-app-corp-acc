import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { Aspects, IAspect, DefaultStackSynthesizer } from 'aws-cdk-lib';
import { CfnRole } from 'aws-cdk-lib/aws-iam';
import { IConstruct } from 'constructs';

// Read target account/region from environment variables — never hardcode account IDs in source.
// Set CDK_TARGET_ACCOUNT and CDK_TARGET_REGION as environment variables in the Amplify console
// (App settings > Environment variables) or in your local shell for local development.
const TARGET_ACCOUNT = process.env.CDK_TARGET_ACCOUNT;
const TARGET_REGION = process.env.CDK_TARGET_REGION ?? 'ap-southeast-2';

if (!TARGET_ACCOUNT) {
  throw new Error(
    'CDK_TARGET_ACCOUNT environment variable is required. ' +
    'Set it in the Amplify console under App settings > Environment variables.'
  );
}

const backend = defineBackend({ auth, data });

// Pin each stack to the target account/region so CDK doesn't fall back to the
// CodeBuild role's account when resolving the bootstrap SSM parameter.
[backend.auth.stack, backend.data.stack].forEach((stack) => {
  (stack as any)._env = {
    account: TARGET_ACCOUNT,
    region: TARGET_REGION,
  };
  (stack as any).synthesizer = new DefaultStackSynthesizer({
    qualifier: 'hnb659fds',
    deployRoleArn: `arn:aws:iam::${TARGET_ACCOUNT}:role/cdk-hnb659fds-deploy-role-${TARGET_ACCOUNT}-${TARGET_REGION}`,
    fileAssetPublishingRoleArn: `arn:aws:iam::${TARGET_ACCOUNT}:role/cdk-hnb659fds-file-publishing-role-${TARGET_ACCOUNT}-${TARGET_REGION}`,
    imageAssetPublishingRoleArn: `arn:aws:iam::${TARGET_ACCOUNT}:role/cdk-hnb659fds-image-publishing-role-${TARGET_ACCOUNT}-${TARGET_REGION}`,
    cloudFormationExecutionRole: `arn:aws:iam::${TARGET_ACCOUNT}:role/cdk-hnb659fds-cfn-exec-role-${TARGET_ACCOUNT}-${TARGET_REGION}`,
    lookupRoleArn: `arn:aws:iam::${TARGET_ACCOUNT}:role/cdk-hnb659fds-lookup-role-${TARGET_ACCOUNT}-${TARGET_REGION}`,
    bootstrapStackVersionSsmParameter: `/cdk-bootstrap/hnb659fds/version`,
  });
});

// Apply TMR Level 3 permission boundary to all IAM roles in Amplify stacks
class TmrPermissionsBoundary implements IAspect {
  visit(node: IConstruct): void {
    if (node instanceof CfnRole) {
      node.addPropertyOverride(
        'PermissionsBoundary',
        `arn:aws:iam::${TARGET_ACCOUNT}:policy/tmr-boundary-level3`
      );
    }
  }
}

[backend.auth.stack, backend.data.stack].forEach((stack) => {
  Aspects.of(stack).add(new TmrPermissionsBoundary());
});
