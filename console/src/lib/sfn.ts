import {
  CreateRoleCommand,
  EntityAlreadyExistsException,
  GetRoleCommand,
  IAMClient,
  ListRolesCommand,
} from '@aws-sdk/client-iam'
import {
  CreateStateMachineCommand,
  DescribeStateMachineCommand,
  ListExecutionsCommand,
  ListStateMachinesCommand,
  SFNClient,
  StateMachineType,
  type ExecutionListItem,
  type StateMachineListItem,
} from '@aws-sdk/client-sfn'
import { config } from './config'
import { emuCreds } from './emu'

const ROLE_NAME = 'stackwrangler-sfn-basic'
const ROLE_ARN = `arn:aws:iam::${config.accountId}:role/${ROLE_NAME}`
const TRUST = JSON.stringify({
  Version: '2012-10-17',
  Statement: [
    {
      Effect: 'Allow',
      Principal: { Service: 'states.amazonaws.com' },
      Action: 'sts:AssumeRole',
    },
  ],
})

export const DEFAULT_PASS_DEFINITION = `{
  "Comment": "A Hello World example of the Amazon States Language using a Pass state",
  "StartAt": "HelloWorld",
  "States": {
    "HelloWorld": {
      "Type": "Pass",
      "Result": { "ok": true },
      "End": true
    }
  }
}`

export const BASIC_SFN_ROLE_NAME = ROLE_NAME

export type RoleOption = { name: string; arn: string }

export type StateMachineDetail = {
  name: string
  stateMachineArn: string
  status: string | undefined
  type: string | undefined
  definition: string
  roleArn: string | undefined
  creationDate: Date | undefined
}

function sfnClient(): SFNClient {
  return new SFNClient(emuCreds())
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

export function stateMachineArnForName(name: string): string {
  return `arn:aws:states:${config.region}:${config.accountId}:stateMachine:${name}`
}

export function typeLabel(type: string | undefined): string {
  if (!type) return '—'
  if (type === 'STANDARD') return 'Standard'
  if (type === 'EXPRESS') return 'Express'
  return type
}

export function prettyDefinition(raw: string | undefined): string {
  if (!raw) return ''
  try {
    return JSON.stringify(JSON.parse(raw), null, 2)
  } catch {
    return raw
  }
}

export async function listStateMachines(): Promise<StateMachineListItem[]> {
  const out = await sfnClient().send(
    new ListStateMachinesCommand({ maxResults: 100 }),
  )
  return out.stateMachines ?? []
}

export async function describeStateMachine(
  nameOrArn: string,
): Promise<StateMachineDetail> {
  const arn = nameOrArn.startsWith('arn:')
    ? nameOrArn
    : stateMachineArnForName(nameOrArn)
  const out = await sfnClient().send(
    new DescribeStateMachineCommand({ stateMachineArn: arn }),
  )
  const name = out.name ?? nameOrArn
  return {
    name,
    stateMachineArn: out.stateMachineArn ?? arn,
    status: out.status,
    type: out.type,
    definition: out.definition ?? '',
    roleArn: out.roleArn,
    creationDate: out.creationDate,
  }
}

export async function listExecutions(
  stateMachineArn: string,
): Promise<ExecutionListItem[]> {
  const out = await sfnClient().send(
    new ListExecutionsCommand({
      stateMachineArn,
      maxResults: 50,
    }),
  )
  return out.executions ?? []
}

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

export async function ensureExecutionRole(): Promise<string> {
  try {
    const got = await iamClient().send(
      new GetRoleCommand({ RoleName: ROLE_NAME }),
    )
    return got.Role?.Arn ?? ROLE_ARN
  } catch {
    /* create below */
  }
  try {
    const created = await iamClient().send(
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

export type CreateStateMachineInput = {
  name: string
  definition: string
  type: 'STANDARD' | 'EXPRESS'
  roleMode: 'create' | 'existing'
  existingRoleArn?: string
}

export async function createStateMachineFromForm(
  input: CreateStateMachineInput,
): Promise<{ stateMachineArn: string; name: string }> {
  let roleArn: string
  if (input.roleMode === 'existing' && input.existingRoleArn) {
    roleArn = input.existingRoleArn.startsWith('arn:')
      ? input.existingRoleArn
      : `arn:aws:iam::${config.accountId}:role/${input.existingRoleArn}`
  } else {
    roleArn = await ensureExecutionRole()
  }

  let definition = input.definition.trim()
  try {
    definition = JSON.stringify(JSON.parse(definition))
  } catch {
    throw new Error('Definition must be valid JSON')
  }

  const out = await sfnClient().send(
    new CreateStateMachineCommand({
      name: input.name,
      definition,
      roleArn,
      type:
        input.type === 'EXPRESS'
          ? StateMachineType.EXPRESS
          : StateMachineType.STANDARD,
    }),
  )
  return {
    stateMachineArn: out.stateMachineArn ?? stateMachineArnForName(input.name),
    name: input.name,
  }
}

export type { ExecutionListItem, StateMachineListItem }
