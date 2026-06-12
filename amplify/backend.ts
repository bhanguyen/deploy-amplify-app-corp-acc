import { defineBackend } from '@aws-amplify/backend';
import { Aspects, CfnResource, IAspect } from 'aws-cdk-lib';
import { IConstruct } from 'constructs';
import { auth } from './auth/resource.js';
import { data } from './data/resource.js';

const backend = defineBackend({
  auth,
  data,
});

/**
 * The TMR cfn-exec-role (bounded by tmr-boundary-level2) can create a role only if
 * that role's permissions boundary is exactly tmr-boundary-level3. cdk.json's
 * permissionsBoundary and a `CfnRole` Aspect both miss roles emitted by CDK's
 * low-level CustomResourceProvider (e.g. S3 autoDeleteObjects) — those are raw
 * CfnResources of type AWS::IAM::Role, not CfnRole constructs. Match the CFN type
 * (not the construct class) so EVERY role in every nested stack gets the boundary.
 */
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
