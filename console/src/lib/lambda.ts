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
  type Architecture,
  type FunctionConfiguration,
} from '@aws-sdk/client-lambda'
import {
  CreateRoleCommand,
  EntityAlreadyExistsException,
  GetRoleCommand,
  IAMClient,
  ListRolesCommand,
} from '@aws-sdk/client-iam'
import JSZip from 'jszip'
import { config } from './config'

/** Minimal nodejs hello zip (index.handler → { ok, echo }) — kept for Create hello shortcut */
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

export const BASIC_ROLE_NAME = ROLE_NAME

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

export async function getFunction(
  name: string,
): Promise<FunctionConfiguration> {
  const got = await lambdaClient().send(
    new GetFunctionCommand({ FunctionName: name }),
  )
  if (!got.Configuration) {
    throw new Error(`Function ${name} has no configuration`)
  }
  return got.Configuration
}

export type RoleOption = { name: string; arn: string }

export async function listExecutionRoles(): Promise<RoleOption[]> {
  const out = await iamClient().send(new ListRolesCommand({}))
  const roles = (out.Roles ?? [])
    .map((r) => ({ name: r.RoleName ?? '', arn: r.Arn ?? '' }))
    .filter((r) => r.name && r.arn)
  if (!roles.some((r) => r.name === ROLE_NAME)) {
    roles.unshift({ name: ROLE_NAME, arn: ROLE_ARN })
  }
  return roles
}

export async function deployZip(
  name: string,
  zipBytes: Uint8Array,
  opts?: {
    createIfMissing?: boolean
    handler?: string
    runtime?: Runtime | string
    roleArn?: string
    description?: string
    architectures?: Architecture[]
  },
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

  const roleArn = opts?.roleArn ?? (await ensureExecutionRole())
  const created = await client.send(
    new CreateFunctionCommand({
      FunctionName: name,
      Runtime: (opts?.runtime as Runtime | undefined) ?? Runtime.nodejs18x,
      Role: roleArn,
      Handler: opts?.handler ?? 'index.handler',
      Description: opts?.description,
      Architectures: opts?.architectures,
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
    Description: created.Description,
    MemorySize: created.MemorySize,
    Timeout: created.Timeout,
    PackageType: created.PackageType,
    Architectures: created.Architectures,
    LastModified: created.LastModified,
    State: created.State,
  }
}

export type CreateFunctionInput = {
  name: string
  runtime: string
  description?: string
  architecture?: 'x86_64' | 'arm64'
  roleMode: 'create' | 'existing'
  existingRoleArn?: string
  codeSource: 'hello' | 'zip'
  zipBytes?: Uint8Array
}

export async function createFunctionFromForm(
  input: CreateFunctionInput,
): Promise<FunctionConfiguration> {
  let roleArn: string
  if (input.roleMode === 'existing' && input.existingRoleArn) {
    roleArn = input.existingRoleArn.startsWith('arn:')
      ? input.existingRoleArn
      : `arn:aws:iam::${config.accountId}:role/${input.existingRoleArn}`
  } else {
    roleArn = await ensureExecutionRole()
  }

  let zipBytes = input.zipBytes
  let handler = 'index.handler'
  if (input.codeSource === 'hello' || !zipBytes) {
    const hello = helloTemplateForRuntime(input.runtime)
    zipBytes = await zipSingleFile(hello.filename, hello.source)
    handler = hello.handler
  }

  return deployZip(input.name, zipBytes, {
    createIfMissing: true,
    runtime: input.runtime,
    handler,
    roleArn,
    description: input.description,
    architectures: input.architecture
      ? [input.architecture]
      : undefined,
  })
}

export async function readFileAsBytes(file: File): Promise<Uint8Array> {
  const buf = await file.arrayBuffer()
  return new Uint8Array(buf)
}

export type FunctionSource = {
  filename: string
  source: string
  language: string
}

/** Download deployment package via GetFunction Code.Location and pick handler file. */
export async function getFunctionSource(
  name: string,
): Promise<FunctionSource> {
  const client = lambdaClient()
  const got = await client.send(new GetFunctionCommand({ FunctionName: name }))
  const location = got.Code?.Location
  const handler = got.Configuration?.Handler ?? 'index.handler'
  const runtime = got.Configuration?.Runtime ?? 'nodejs20.x'
  if (!location) {
    throw new Error('GetFunction returned no Code.Location')
  }
  const url = rewriteCodeLocation(location)
  const res = await fetch(url)
  if (!res.ok) {
    throw new Error(`Download function code failed: HTTP ${res.status}`)
  }
  const buf = await res.arrayBuffer()
  const zip = await JSZip.loadAsync(buf)
  const preferred = handlerToCandidates(handler, runtime)
  let filename = preferred.find((f) => zip.file(f)) ?? ''
  if (!filename) {
    const names = Object.keys(zip.files).filter(
      (n) => !zip.files[n]?.dir && !n.startsWith('__MACOSX'),
    )
    filename =
      names.find((n) => /\.(js|mjs|cjs|ts|py|java|go|rb|php)$/i.test(n)) ??
      names[0] ??
      ''
  }
  if (!filename) {
    throw new Error('Deployment package has no source files')
  }
  const entry = zip.file(filename)
  if (!entry) {
    throw new Error(`Missing ${filename} in deployment package`)
  }
  const source = await entry.async('string')
  return {
    filename,
    source,
    language: languageForFile(filename),
  }
}

export async function updateFunctionSource(
  name: string,
  filename: string,
  source: string,
): Promise<FunctionConfiguration> {
  const client = lambdaClient()
  const got = await client.send(new GetFunctionCommand({ FunctionName: name }))
  const location = got.Code?.Location
  let zip: JSZip
  if (location) {
    const res = await fetch(rewriteCodeLocation(location))
    if (res.ok) {
      zip = await JSZip.loadAsync(await res.arrayBuffer())
    } else {
      zip = new JSZip()
    }
  } else {
    zip = new JSZip()
  }
  zip.file(filename, source)
  const packed = await zip.generateAsync({ type: 'uint8array' })
  await client.send(
    new UpdateFunctionCodeCommand({
      FunctionName: name,
      ZipFile: packed,
    }),
  )
  await waitUntilActive(client, name)
  const after = await client.send(new GetFunctionCommand({ FunctionName: name }))
  if (!after.Configuration) {
    throw new Error('update-function-code left no configuration')
  }
  return after.Configuration
}

async function zipSingleFile(
  filename: string,
  source: string,
): Promise<Uint8Array> {
  const zip = new JSZip()
  zip.file(filename, source)
  return zip.generateAsync({ type: 'uint8array' })
}

function helloTemplateForRuntime(runtime: string): {
  filename: string
  handler: string
  source: string
} {
  if (runtime.startsWith('python')) {
    return {
      filename: 'lambda_function.py',
      handler: 'lambda_function.handler',
      source: `import json

def handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"message": "Hello from awsbox", "event": event}),
    }
`,
    }
  }
  return {
    filename: 'index.js',
    handler: 'index.handler',
    source: `// Hello world template
exports.handler = async (event) => {
  const message = "Hello from awsbox";
  return {
    statusCode: 200,
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message, event }),
  };
};
`,
  }
}

function handlerToCandidates(handler: string, runtime: string): string[] {
  const base = handler.split('.')[0] || 'index'
  if (runtime.startsWith('python')) {
    return [`${base}.py`, 'lambda_function.py', 'index.py']
  }
  return [`${base}.js`, `${base}.mjs`, `${base}.cjs`, `${base}.ts`, 'index.js']
}

function languageForFile(filename: string): string {
  const lower = filename.toLowerCase()
  if (lower.endsWith('.py')) return 'python'
  if (lower.endsWith('.ts')) return 'typescript'
  if (lower.endsWith('.java')) return 'java'
  if (lower.endsWith('.go')) return 'go'
  if (lower.endsWith('.rb')) return 'ruby'
  if (lower.endsWith('.php')) return 'php'
  return 'javascript'
}

/** Browser: LocalEmu Code.Location is :4566 — hit Vite /aws-iam proxy instead. */
function rewriteCodeLocation(location: string): string {
  try {
    const u = new URL(location)
    if (
      u.hostname === 'localhost' ||
      u.hostname === '127.0.0.1' ||
      u.port === '4566'
    ) {
      return `/aws-iam${u.pathname}${u.search}`
    }
  } catch {
    /* keep original */
  }
  return location
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
