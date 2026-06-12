import { referenceAuth } from "@aws-amplify/backend";

/**
 * Reference the shared, externally-managed Cognito user pool (the
 * tau-b2032-shared-cognito CloudFormation stack) instead of provisioning a new
 * one per app. IDs/ARNs are injected as Amplify app environment variables.
 *
 * @see https://docs.amplify.aws/react/build-a-backend/auth/use-existing-cognito-resources/
 */
export const auth = referenceAuth({
  userPoolId: process.env.SHARED_USER_POOL_ID!,
  userPoolClientId: process.env.SHARED_USER_POOL_CLIENT_ID!,
  identityPoolId: process.env.SHARED_IDENTITY_POOL_ID!,
  authRoleArn: process.env.SHARED_AUTH_ROLE_ARN!,
  unauthRoleArn: process.env.SHARED_UNAUTH_ROLE_ARN!,
});
