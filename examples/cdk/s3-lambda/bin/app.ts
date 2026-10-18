#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib'
import { AwsboxS3LambdaStack } from '../lib/awsbox-s3-lambda-stack'

const app = new cdk.App()
new AwsboxS3LambdaStack(app, 'AwsboxCdkS3Lambda', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT ?? '000000000000',
    region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1',
  },
})
