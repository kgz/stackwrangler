import {
  CloudWatchLogsClient,
  CreateLogGroupCommand,
  DescribeLogGroupsCommand,
  DescribeLogStreamsCommand,
  FilterLogEventsCommand,
  PutRetentionPolicyCommand,
  type FilteredLogEvent,
  type LogGroup,
  type LogStream,
} from '@aws-sdk/client-cloudwatch-logs'
import { emuCreds } from './emu'

function logsClient(): CloudWatchLogsClient {
  return new CloudWatchLogsClient(emuCreds())
}

export async function listLogGroups(
  prefix?: string,
): Promise<LogGroup[]> {
  const out = await logsClient().send(
    new DescribeLogGroupsCommand({
      logGroupNamePrefix: prefix,
      limit: 50,
    }),
  )
  return out.logGroups ?? []
}

export async function getLogGroup(
  logGroupName: string,
): Promise<LogGroup | undefined> {
  const groups = await listLogGroups(logGroupName)
  return groups.find((g) => g.logGroupName === logGroupName)
}

export async function createLogGroup(
  logGroupName: string,
  retentionInDays?: number,
): Promise<void> {
  await logsClient().send(
    new CreateLogGroupCommand({
      logGroupName,
    }),
  )
  if (retentionInDays !== undefined && retentionInDays > 0) {
    await logsClient().send(
      new PutRetentionPolicyCommand({
        logGroupName,
        retentionInDays,
      }),
    )
  }
}

export async function listLogStreams(
  logGroupName: string,
  prefix?: string,
): Promise<LogStream[]> {
  const out = await logsClient().send(
    new DescribeLogStreamsCommand({
      logGroupName,
      logStreamNamePrefix: prefix || undefined,
      orderBy: prefix ? undefined : 'LastEventTime',
      descending: prefix ? undefined : true,
      limit: 50,
    }),
  )
  return out.logStreams ?? []
}

export type FilterLogEventsOpts = {
  logGroupName: string
  filterPattern?: string
  logStreamNames?: string[]
  limit?: number
}

export async function filterLogEvents(
  opts: FilterLogEventsOpts | string,
  limit = 50,
): Promise<FilteredLogEvent[]> {
  const params =
    typeof opts === 'string'
      ? { logGroupName: opts, limit }
      : {
          logGroupName: opts.logGroupName,
          filterPattern: opts.filterPattern?.trim() || undefined,
          logStreamNames:
            opts.logStreamNames && opts.logStreamNames.length > 0
              ? opts.logStreamNames
              : undefined,
          limit: opts.limit ?? 50,
        }
  const out = await logsClient().send(
    new FilterLogEventsCommand({
      ...params,
      interleaved: true,
    }),
  )
  return out.events ?? []
}

export function lambdaLogGroupName(functionName: string): string {
  return `/aws/lambda/${functionName}`
}

export function retentionLabel(days: number | undefined): string {
  if (!days) return 'Never expire'
  if (days === 1) return '1 day'
  if (days === 7) return '1 week'
  if (days === 14) return '2 weeks'
  if (days === 30) return '1 month'
  if (days === 60) return '2 months'
  if (days === 90) return '3 months'
  if (days === 120) return '4 months'
  if (days === 180) return '6 months'
  if (days === 365) return '1 year'
  if (days === 400) return '13 months'
  if (days === 545) return '18 months'
  if (days === 731) return '2 years'
  if (days === 1827) return '5 years'
  if (days === 3653) return '10 years'
  return days === 1 ? '1 day' : `${days} days`
}

export const RETENTION_OPTIONS: Array<{ value: string; label: string }> = [
  { value: '', label: 'Never expire' },
  { value: '1', label: '1 day' },
  { value: '3', label: '3 days' },
  { value: '5', label: '5 days' },
  { value: '7', label: '1 week' },
  { value: '14', label: '2 weeks' },
  { value: '30', label: '1 month' },
  { value: '60', label: '2 months' },
  { value: '90', label: '3 months' },
  { value: '120', label: '4 months' },
  { value: '180', label: '6 months' },
  { value: '365', label: '1 year' },
  { value: '400', label: '13 months' },
  { value: '545', label: '18 months' },
  { value: '731', label: '2 years' },
  { value: '1827', label: '5 years' },
  { value: '3653', label: '10 years' },
]
