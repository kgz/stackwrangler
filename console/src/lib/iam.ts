import {
  AttachUserPolicyCommand,
  CreateAccessKeyCommand,
  CreatePolicyCommand,
  CreateUserCommand,
  DeleteAccessKeyCommand,
  DeletePolicyCommand,
  DeleteUserCommand,
  DetachUserPolicyCommand,
  IAMClient,
  ListUsersCommand,
  type User,
} from '@aws-sdk/client-iam'
import {
  ListBucketsCommand,
  S3Client,
  S3ServiceException,
} from '@aws-sdk/client-s3'
import { config } from './config'

function iamClient(): IAMClient {
  return new IAMClient({
    region: config.region,
    endpoint: config.iamEndpoint,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
  })
}

function localstackS3(accessKeyId: string, secretAccessKey: string): S3Client {
  return new S3Client({
    region: config.region,
    endpoint: config.iamEndpoint,
    forcePathStyle: true,
    credentials: { accessKeyId, secretAccessKey },
  })
}

export async function listUsers(): Promise<User[]> {
  const out = await iamClient().send(new ListUsersCommand({}))
  return out.Users ?? []
}

const DENY_LIST_BUCKETS = JSON.stringify({
  Version: '2012-10-17',
  Statement: [
    {
      Sid: 'DenyListBuckets',
      Effect: 'Deny',
      Action: 's3:ListAllMyBuckets',
      Resource: '*',
    },
  ],
})

export type AccessDeniedLabResult = {
  userName: string
  denied: boolean
  message: string
}

export async function runAccessDeniedLab(): Promise<AccessDeniedLabResult> {
  const client = iamClient()
  const userName = `awsbox-denied-${Date.now()}`
  let policyArn: string | undefined
  let accessKeyId: string | undefined

  try {
    await client.send(new CreateUserCommand({ UserName: userName }))

    const policy = await client.send(
      new CreatePolicyCommand({
        PolicyName: `AwsboxDenyS3List-${userName}`,
        PolicyDocument: DENY_LIST_BUCKETS,
      }),
    )
    policyArn = policy.Policy?.Arn
    if (!policyArn) {
      throw new Error('create-policy returned no Arn')
    }

    await client.send(
      new AttachUserPolicyCommand({
        UserName: userName,
        PolicyArn: policyArn,
      }),
    )

    const keys = await client.send(
      new CreateAccessKeyCommand({ UserName: userName }),
    )
    accessKeyId = keys.AccessKey?.AccessKeyId
    const secret = keys.AccessKey?.SecretAccessKey
    if (!accessKeyId || !secret) {
      throw new Error('create-access-key returned incomplete credentials')
    }

    try {
      await localstackS3(accessKeyId, secret).send(new ListBucketsCommand({}))
      return {
        userName,
        denied: false,
        message: 'Expected AccessDenied, but ListBuckets succeeded',
      }
    } catch (err) {
      const msg = formatDenial(err)
      const denied =
        /AccessDenied|not authorized|ExplicitDeny|Unauthorized/i.test(msg)
      return { userName, denied, message: msg }
    }
  } finally {
    await cleanupLab(client, userName, policyArn, accessKeyId)
  }
}

function formatDenial(err: unknown): string {
  if (err instanceof S3ServiceException) {
    return `${err.name}: ${err.message}`
  }
  if (err instanceof Error) {
    return err.message
  }
  return String(err)
}

async function cleanupLab(
  client: IAMClient,
  userName: string,
  policyArn: string | undefined,
  accessKeyId: string | undefined,
): Promise<void> {
  if (accessKeyId) {
    try {
      await client.send(
        new DeleteAccessKeyCommand({
          UserName: userName,
          AccessKeyId: accessKeyId,
        }),
      )
    } catch {
      /* ignore */
    }
  }
  if (policyArn) {
    try {
      await client.send(
        new DetachUserPolicyCommand({
          UserName: userName,
          PolicyArn: policyArn,
        }),
      )
    } catch {
      /* ignore */
    }
    try {
      await client.send(new DeletePolicyCommand({ PolicyArn: policyArn }))
    } catch {
      /* ignore */
    }
  }
  try {
    await client.send(new DeleteUserCommand({ UserName: userName }))
  } catch {
    /* ignore */
  }
}
