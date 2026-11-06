import {
  CloudFormationClient,
  CreateStackCommand,
  DeleteStackCommand,
  DescribeStackEventsCommand,
  DescribeStackResourcesCommand,
  DescribeStacksCommand,
  GetTemplateCommand,
  ListStacksCommand,
  StackStatus,
  type Capability,
  type Output,
  type Parameter,
  type Stack,
  type StackEvent,
  type StackResource,
  type StackSummary,
} from '@aws-sdk/client-cloudformation'
import { emuCreds } from './emu'

const DEFAULT_CAPABILITIES: Capability[] = [
  'CAPABILITY_IAM',
  'CAPABILITY_NAMED_IAM',
  'CAPABILITY_AUTO_EXPAND',
]

function client() {
  return new CloudFormationClient(emuCreds())
}

const ACTIVE_STATUSES: StackStatus[] = [
  StackStatus.CREATE_IN_PROGRESS,
  StackStatus.CREATE_FAILED,
  StackStatus.CREATE_COMPLETE,
  StackStatus.ROLLBACK_IN_PROGRESS,
  StackStatus.ROLLBACK_FAILED,
  StackStatus.ROLLBACK_COMPLETE,
  StackStatus.DELETE_IN_PROGRESS,
  StackStatus.DELETE_FAILED,
  StackStatus.UPDATE_IN_PROGRESS,
  StackStatus.UPDATE_COMPLETE_CLEANUP_IN_PROGRESS,
  StackStatus.UPDATE_COMPLETE,
  StackStatus.UPDATE_FAILED,
  StackStatus.UPDATE_ROLLBACK_IN_PROGRESS,
  StackStatus.UPDATE_ROLLBACK_FAILED,
  StackStatus.UPDATE_ROLLBACK_COMPLETE,
  StackStatus.REVIEW_IN_PROGRESS,
  StackStatus.IMPORT_IN_PROGRESS,
  StackStatus.IMPORT_COMPLETE,
  StackStatus.IMPORT_ROLLBACK_IN_PROGRESS,
  StackStatus.IMPORT_ROLLBACK_FAILED,
  StackStatus.IMPORT_ROLLBACK_COMPLETE,
]

export async function listStacks(
  includeDeleted = false,
): Promise<StackSummary[]> {
  const out = await client().send(
    new ListStacksCommand(
      includeDeleted ? undefined : { StackStatusFilter: ACTIVE_STATUSES },
    ),
  )
  return out.StackSummaries ?? []
}

export async function describeStack(stackName: string): Promise<Stack | null> {
  const out = await client().send(
    new DescribeStacksCommand({ StackName: stackName }),
  )
  return out.Stacks?.[0] ?? null
}

export async function listStackEvents(
  stackName: string,
): Promise<StackEvent[]> {
  const out = await client().send(
    new DescribeStackEventsCommand({ StackName: stackName }),
  )
  return out.StackEvents ?? []
}

export async function listStackResources(
  stackName: string,
): Promise<StackResource[]> {
  const out = await client().send(
    new DescribeStackResourcesCommand({ StackName: stackName }),
  )
  return out.StackResources ?? []
}

export async function getStackTemplate(stackName: string): Promise<string> {
  const out = await client().send(
    new GetTemplateCommand({ StackName: stackName }),
  )
  return out.TemplateBody ?? ''
}

export async function deleteStack(stackName: string): Promise<void> {
  await client().send(new DeleteStackCommand({ StackName: stackName }))
}

export async function createStack(input: {
  stackName: string
  templateBody: string
  capabilities?: Capability[]
}): Promise<string | undefined> {
  const out = await client().send(
    new CreateStackCommand({
      StackName: input.stackName,
      TemplateBody: input.templateBody,
      Capabilities: input.capabilities ?? DEFAULT_CAPABILITIES,
    }),
  )
  return out.StackId
}

export function isStackBusy(status: string | undefined): boolean {
  if (!status) return false
  return status.includes('IN_PROGRESS')
}

export type { Output, Parameter, Stack, StackEvent, StackResource, StackSummary }
