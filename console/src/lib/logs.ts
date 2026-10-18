import {
  CloudWatchLogsClient,
  DescribeLogGroupsCommand,
  FilterLogEventsCommand,
  type FilteredLogEvent,
  type LogGroup,
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

export async function filterLogEvents(
  logGroupName: string,
  limit = 50,
): Promise<FilteredLogEvent[]> {
  const out = await logsClient().send(
    new FilterLogEventsCommand({
      logGroupName,
      limit,
      interleaved: true,
    }),
  )
  return out.events ?? []
}

export function lambdaLogGroupName(functionName: string): string {
  return `/aws/lambda/${functionName}`
}
