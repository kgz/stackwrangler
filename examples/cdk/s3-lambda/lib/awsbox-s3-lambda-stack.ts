import * as cdk from 'aws-cdk-lib'
import * as iam from 'aws-cdk-lib/aws-iam'
import * as lambda from 'aws-cdk-lib/aws-lambda'
import * as s3 from 'aws-cdk-lib/aws-s3'
import { Construct } from 'constructs'

/** Same S3 + Lambda writer as examples/cloudformation/s3-lambda (L1 + params). */
export class AwsboxS3LambdaStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props)

    const bucketName = new cdk.CfnParameter(this, 'BucketName', {
      type: 'String',
    })
    const functionName = new cdk.CfnParameter(this, 'FunctionName', {
      type: 'String',
    })
    const codeBucket = new cdk.CfnParameter(this, 'CodeBucket', {
      type: 'String',
      description: 'Staging bucket holding function.zip (LocalEmu S3)',
    })
    const codeKey = new cdk.CfnParameter(this, 'CodeKey', {
      type: 'String',
      default: 'function.zip',
    })

    new s3.CfnBucket(this, 'DemoBucket', {
      bucketName: bucketName.valueAsString,
    })

    const role = new iam.CfnRole(this, 'LambdaRole', {
      roleName: cdk.Fn.join('', [functionName.valueAsString, '-role']),
      assumeRolePolicyDocument: {
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Principal: { Service: 'lambda.amazonaws.com' },
            Action: 'sts:AssumeRole',
          },
        ],
      },
      policies: [
        {
          policyName: cdk.Fn.join('', [functionName.valueAsString, '-s3']),
          policyDocument: {
            Version: '2012-10-17',
            Statement: [
              {
                Effect: 'Allow',
                Action: ['s3:PutObject', 's3:GetObject', 's3:ListBucket'],
                Resource: [
                  cdk.Fn.sub('arn:aws:s3:::${BucketName}', {
                    BucketName: bucketName.valueAsString,
                  }),
                  cdk.Fn.sub('arn:aws:s3:::${BucketName}/*', {
                    BucketName: bucketName.valueAsString,
                  }),
                ],
              },
              {
                Effect: 'Allow',
                Action: [
                  'logs:CreateLogGroup',
                  'logs:CreateLogStream',
                  'logs:PutLogEvents',
                ],
                Resource: '*',
              },
            ],
          },
        },
      ],
    })

    const fn = new lambda.CfnFunction(this, 'WriterFunction', {
      functionName: functionName.valueAsString,
      runtime: 'nodejs18.x',
      handler: 'index.handler',
      timeout: 30,
      role: role.attrArn,
      environment: {
        variables: {
          BUCKET_NAME: bucketName.valueAsString,
        },
      },
      code: {
        s3Bucket: codeBucket.valueAsString,
        s3Key: codeKey.valueAsString,
      },
    })
    fn.addResourceDependency(role)

    new cdk.CfnOutput(this, 'BucketNameOut', {
      value: bucketName.valueAsString,
    })
    new cdk.CfnOutput(this, 'FunctionNameOut', {
      value: functionName.valueAsString,
    })
  }
}
