import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource.js';
import { data } from './data/resource.js';
import { PermissionsBoundary } from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';

const backend = defineBackend({
  auth,
  data,
});

// Disable self-signup - only admins can create users
const { cfnUserPool } = backend.auth.resources.cfnResources;
cfnUserPool.adminCreateUserConfig = {
  allowAdminCreateUserOnly: true,
};

// Apply TMR Level 2 boundary to all Amplify application stacks
[backend.auth.stack, backend.data.stack].forEach((stack) => {
  PermissionsBoundary.of(stack).apply(
    iam.ManagedPolicy.fromManagedPolicyName(
      stack,
      'TmrLevelTwoBoundary',
      'tmr-boundary-level2'   // Level 2 = application roles
    )
  );
});
