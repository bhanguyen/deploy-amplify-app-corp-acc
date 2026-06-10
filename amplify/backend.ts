import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { Aspects, IAspect } from 'aws-cdk-lib';
import { CfnRole } from 'aws-cdk-lib/aws-iam';
import { IConstruct } from 'constructs';

const backend = defineBackend({ auth, data });

// Apply TMR Level 3 permission boundary to all IAM roles in Amplify stacks.
// CDK_DEFAULT_ACCOUNT is set at build time via amplify.yml so node.stack.account
// resolves to your account (471112770810), not the CodeBuild role's account.
class TmrPermissionsBoundary implements IAspect {
  visit(node: IConstruct): void {
    if (node instanceof CfnRole) {
      node.addPropertyOverride(
        'PermissionsBoundary',
        `arn:aws:iam::${node.stack.account}:policy/tmr-boundary-level3`
      );
    }
  }
}

[backend.auth.stack, backend.data.stack].forEach((stack) => {
  Aspects.of(stack).add(new TmrPermissionsBoundary());
});
