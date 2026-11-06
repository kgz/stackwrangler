import {
  CloudFormationClient,
  DeleteStackCommand,
  DescribeStackEventsCommand,
  DescribeStackResourcesCommand,
  DescribeStacksCommand,
  GetTemplateCommand,
  ListStackSetsCommand,
  ListStacksCommand,
  StackStatus,
  type Output,
  type Parameter,
  type Stack,
  type StackEvent,
  type StackResource,
  type StackSetSummary,
  type StackSummary,
} from '@aws-sdk/client-cloudformation'
import { emuCreds } from './emu'

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
  Output,
  Parameter,
  Stack,
  StackEvent,
  StackResource,
  StackSetSummary,
  StackSummary,
}
