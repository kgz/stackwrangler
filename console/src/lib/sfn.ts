import {
  DescribeStateMachineCommand,
  ListExecutionsCommand,
  ListStateMachinesCommand,
  SFNClient,
  StartExecutionCommand,
  type ExecutionListItem,
  type StateMachineListItem,
} from '@aws-sdk/client-sfn'
import { config } from './config'
import { emuCreds } from './emu'

export type StateMachineDetail = {
  name: string
  stateMachineArn: string
  status: string | undefined
  type: string | undefined
  definition: string
  roleArn: string | undefined
  creationDate: Date | undefined
}

export type StartExecutionInput = {
  stateMachineArn: string
  name?: string
  input?: string
}

export type StartExecutionResult = {
  executionArn: string
  startDate: Date | undefined
}

function sfnClient(): SFNClient {
  return new SFNClient(emuCreds())
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

export async function startExecution(
  input: StartExecutionInput,
): Promise<StartExecutionResult> {
  let payload = (input.input ?? '{}').trim() || '{}'
  try {
    payload = JSON.stringify(JSON.parse(payload))
  } catch {
    throw new Error('Input must be valid JSON')
  }

  const name = input.name?.trim()
  const out = await sfnClient().send(
    new StartExecutionCommand({
      stateMachineArn: input.stateMachineArn,
      input: payload,
      ...(name ? { name } : {}),
    }),
  )
  const executionArn = out.executionArn
  if (!executionArn) {
    throw new Error('StartExecution returned no executionArn')
  }
  return {
    executionArn,
    startDate: out.startDate,
  }
}

export type { ExecutionListItem, StateMachineListItem }
