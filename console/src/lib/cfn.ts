import {
  CloudFormationClient,
  CreateChangeSetCommand,
  CreateStackCommand,
  DeleteChangeSetCommand,
  DeleteStackCommand,
  DescribeChangeSetCommand,
  DescribeStackEventsCommand,
  DescribeStackResourcesCommand,
  DescribeStacksCommand,
  ExecuteChangeSetCommand,
  GetTemplateCommand,
  ListChangeSetsCommand,
  ListStackSetsCommand,
  ListStacksCommand,
  StackStatus,
  UpdateStackCommand,
  type Capability,
  type Change,
  type ChangeSetSummary,
  type Output,
  type Parameter,
  type Stack,
  type StackEvent,
  type StackResource,
  type StackSetSummary,
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

export async function updateStack(input: {
  stackName: string
  templateBody: string
}): Promise<void> {
  await client().send(
    new UpdateStackCommand({
      StackName: input.stackName,
      TemplateBody: input.templateBody,
    }),
  )
}

export async function listChangeSets(
  stackName: string,
): Promise<ChangeSetSummary[]> {
  const out = await client().send(
    new ListChangeSetsCommand({ StackName: stackName }),
  )
  return out.Summaries ?? []
}

export type ChangeSetDetail = {
  changeSetName?: string
  changeSetId?: string
  stackName?: string
  description?: string
  status?: string
  statusReason?: string
  executionStatus?: string
  creationTime?: Date
  changes: Change[]
}

export async function describeChangeSet(input: {
  stackName: string
  changeSetName: string
}): Promise<ChangeSetDetail> {
  const out = await client().send(
    new DescribeChangeSetCommand({
      StackName: input.stackName,
      ChangeSetName: input.changeSetName,
    }),
  )
  return {
    changeSetName: out.ChangeSetName,
    changeSetId: out.ChangeSetId,
    stackName: out.StackName,
    description: out.Description,
    status: out.Status,
    statusReason: out.StatusReason,
    executionStatus: out.ExecutionStatus,
    creationTime: out.CreationTime,
    changes: out.Changes ?? [],
  }
}

export async function createChangeSet(input: {
  stackName: string
  changeSetName: string
  description?: string
  templateBody: string
}): Promise<string | undefined> {
  const out = await client().send(
    new CreateChangeSetCommand({
      StackName: input.stackName,
      ChangeSetName: input.changeSetName,
      Description: input.description,
      TemplateBody: input.templateBody,
      ChangeSetType: 'UPDATE',
    }),
  )
  return out.Id
}

export async function executeChangeSet(input: {
  stackName: string
  changeSetName: string
}): Promise<void> {
  await client().send(
    new ExecuteChangeSetCommand({
      StackName: input.stackName,
      ChangeSetName: input.changeSetName,
    }),
  )
}

export async function deleteChangeSet(input: {
  stackName: string
  changeSetName: string
}): Promise<void> {
  await client().send(
    new DeleteChangeSetCommand({
      StackName: input.stackName,
      ChangeSetName: input.changeSetName,
    }),
  )
}

/** ListStackSets — LocalEmu often returns [] even after CreateStackSet (see docs/cfn-stacksets-nested.md). */
export async function listStackSets(): Promise<StackSetSummary[]> {
  const out = await client().send(new ListStackSetsCommand({}))
  return out.Summaries ?? []
}

/** Extract stack name from a stack ARN or bare name. */
export function stackNameFromId(stackIdOrName: string | undefined): string | null {
  if (!stackIdOrName) return null
  const trimmed = stackIdOrName.trim()
  if (!trimmed) return null
  const arn = /^arn:aws:cloudformation:[^:]+:[^:]*:stack\/([^/]+)\//.exec(
    trimmed,
  )
  if (arn?.[1]) return arn[1]
  if (trimmed.includes('/')) return null
  return trimmed
}

export function isNestedStackResource(resourceType: string | undefined): boolean {
  return resourceType === 'AWS::CloudFormation::Stack'
}

export type {
  Change,
  ChangeSetSummary,
  Output,
  Parameter,
  Stack,
  StackEvent,
  StackResource,
  StackSetSummary,
  StackSummary,
}
