import {
  CreateFunctionCommand,
  GetFunctionCommand,
  InvokeCommand,
  LambdaClient,
  ListFunctionsCommand,
  ResourceConflictException,
  ResourceNotFoundException,
  Runtime,
  UpdateFunctionCodeCommand,
  type FunctionConfiguration,
} from '@aws-sdk/client-lambda'
import {
  CreateRoleCommand,
  EntityAlreadyExistsException,
  GetRoleCommand,
  IAMClient,
} from '@aws-sdk/client-iam'
import { config } from './config'

/** Minimal nodejs hello zip (index.handler → { ok, echo }) */
const HELLO_ZIP_B64 =
  'UEsDBBQAAAAIAOxzUl2cSYkiTgAAAFQAAAAIAAAAaW5kZXguanMdykEKgCAQBdC9p/jLgugAhnkWsQEhGWMco5DuXgRv+eg6imidU+Atk8Ah1JsjBjqJdYRb0Q0gpE0YHWW3UGk0gWIqFn+D9+CWM57FfF5QSwECFAMUAAAACADsc1JdnEmJIk4AAABUAAAACAAAAAAAAAAAAAAAgAEAAAAAaW5kZXguanNQSwUGAAAAAAEAAQA2AAAAdAAAAAAA'

const ROLE_NAME = 'awsbox-lambda-basic'
const ROLE_ARN = `arn:aws:iam::${config.accountId}:role/${ROLE_NAME}`
const TRUST = JSON.stringify({
  Version: '2012-10-17',
  Statement: [
    {
      Effect: 'Allow',
      Principal: { Service: 'lambda.amazonaws.com' },
      Action: 'sts:AssumeRole',
    },
  ],
})

function lambdaClient(): LambdaClient {
  return new LambdaClient({
    region: config.region,
    endpoint: config.iamEndpoint,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
  })
}

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

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i += 1) {
    out[i] = bin.charCodeAt(i)
  }
  return out
}

export async function listFunctions(): Promise<FunctionConfiguration[]> {
  const out = await lambdaClient().send(new ListFunctionsCommand({}))
  return out.Functions ?? []
}

export async function deployZip(
  name: string,
  zipBytes: Uint8Array,
  opts?: { createIfMissing?: boolean; handler?: string; runtime?: Runtime },
): Promise<FunctionConfiguration> {
  const client = lambdaClient()
  const createIfMissing = opts?.createIfMissing ?? true
  let exists = false
  try {
    await client.send(new GetFunctionCommand({ FunctionName: name }))
    exists = true
  } catch (err) {
    if (!(err instanceof ResourceNotFoundException) && !isNoSuchEntity(err)) {
      throw err
    }
  }

  if (exists) {
    await client.send(
      new UpdateFunctionCodeCommand({
        FunctionName: name,
        ZipFile: zipBytes,
      }),
    )
    await waitUntilActive(client, name)
    const got = await client.send(new GetFunctionCommand({ FunctionName: name }))
    if (!got.Configuration) {
      throw new Error('update-function-code left no configuration')
    }
    return got.Configuration
  }

  if (!createIfMissing) {
    throw new Error(`Function ${name} not found`)
  }

  const roleArn = await ensureExecutionRole()
  const created = await client.send(
    new CreateFunctionCommand({
      FunctionName: name,
      Runtime: opts?.runtime ?? Runtime.nodejs18x,
      Role: roleArn,
      Handler: opts?.handler ?? 'index.handler',
      Code: { ZipFile: zipBytes },
    }),
  )
  if (!created.FunctionName) {
    throw new Error('create-function returned no name')
  }
  await waitUntilActive(client, created.FunctionName)
  return {
    FunctionName: created.FunctionName,
    FunctionArn: created.FunctionArn,
    Runtime: created.Runtime,
    Handler: created.Handler,
    Role: created.Role,
  }
}

export async function readFileAsBytes(file: File): Promise<Uint8Array> {
  const buf = await file.arrayBuffer()
  return new Uint8Array(buf)
}

async function ensureExecutionRole(): Promise<string> {
  const iam = iamClient()
  try {
    const got = await iam.send(new GetRoleCommand({ RoleName: ROLE_NAME }))
    return got.Role?.Arn ?? ROLE_ARN
  } catch (err) {
    if (!isNoSuchEntity(err)) {
      throw err
    }
  }
  try {
    const created = await iam.send(
      new CreateRoleCommand({
        RoleName: ROLE_NAME,
        AssumeRolePolicyDocument: TRUST,
      }),
    )
    return created.Role?.Arn ?? ROLE_ARN
  } catch (err) {
    if (err instanceof EntityAlreadyExistsException) {
      return ROLE_ARN
    }
    throw err
  }
}

function isNoSuchEntity(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'name' in err &&
    err.name === 'NoSuchEntityException'
  )
}

export async function createHelloFunction(
  name: string,
): Promise<FunctionConfiguration> {
  const roleArn = await ensureExecutionRole()
  const client = lambdaClient()
  try {
    const existing = await client.send(
      new GetFunctionCommand({ FunctionName: name }),
    )
    if (existing.Configuration) {
      return existing.Configuration
    }
  } catch (err) {
    if (!(err instanceof ResourceNotFoundException) && !isNoSuchEntity(err)) {
      throw err
    }
  }

  const created = await client.send(
    new CreateFunctionCommand({
      FunctionName: name,
      Runtime: 'nodejs18.x',
      Role: roleArn,
      Handler: 'index.handler',
      Code: { ZipFile: b64ToBytes(HELLO_ZIP_B64) },
    }),
  )
  if (!created.FunctionArn) {
    throw new Error('create-function returned no FunctionArn')
  }
  await waitUntilActive(client, name)
  return {
    FunctionName: created.FunctionName,
    FunctionArn: created.FunctionArn,
    Runtime: created.Runtime,
    Handler: created.Handler,
    Role: created.Role,
  }
}

async function waitUntilActive(
  client: LambdaClient,
  name: string,
  attempts = 60,
): Promise<void> {
  for (let i = 0; i < attempts; i += 1) {
    const got = await client.send(new GetFunctionCommand({ FunctionName: name }))
    if (got.Configuration?.State === 'Active') {
      return
    }
    await sleep(2000)
  }
  throw new Error(`Function ${name} did not become Active in time`)
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms)
  })
}

export type InvokeResult = {
  statusCode: number
  payloadText: string
}

export async function invokeFunction(
  name: string,
  payload: unknown,
): Promise<InvokeResult> {
  const client = lambdaClient()
  await waitUntilActive(client, name)
  let lastErr: unknown
  for (let i = 0; i < 5; i += 1) {
    try {
      const out = await client.send(
        new InvokeCommand({
          FunctionName: name,
          Payload: new TextEncoder().encode(JSON.stringify(payload)),
        }),
      )
      const statusCode = out.StatusCode ?? 0
      let payloadText = ''
      if (out.Payload) {
        payloadText = new TextDecoder().decode(out.Payload)
      }
      return { statusCode, payloadText }
    } catch (err) {
      lastErr = err
      if (err instanceof ResourceConflictException) {
        await sleep(2000)
        continue
      }
      throw err
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr))
}
