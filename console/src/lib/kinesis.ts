import {
  DescribeStreamSummaryCommand,
  KinesisClient,
  ListStreamsCommand,
} from '@aws-sdk/client-kinesis'
import { emuCreds } from './emu'

export type KinesisStreamRow = {
  name: string
  arn: string
  status: string
  capacityMode: string
  monitoring: string
  createdOn: Date | undefined
}

function kinesisClient(): KinesisClient {
  return new KinesisClient(emuCreds())
}

function capacityLabel(mode: string | undefined): string {
  if (mode === 'ON_DEMAND') return 'On-demand'
  if (mode === 'PROVISIONED') return 'Provisioned'
  if (!mode) return 'Provisioned'
  return mode
}

async function listStreamNames(): Promise<string[]> {
  const names: string[] = []
  let exclusiveStartStreamName: string | undefined
  for (;;) {
    const out = await kinesisClient().send(
      new ListStreamsCommand({
        Limit: 100,
        ExclusiveStartStreamName: exclusiveStartStreamName,
      }),
    )
    for (const name of out.StreamNames ?? []) {
      if (name) names.push(name)
    }
    if (!out.HasMoreStreams) break
    exclusiveStartStreamName = names[names.length - 1]
    if (!exclusiveStartStreamName) break
  }
  return names
}

export async function listDataStreams(): Promise<KinesisStreamRow[]> {
  const names = await listStreamNames()
  const rows = await Promise.all(
    names.map(async (name) => {
      try {
        const out = await kinesisClient().send(
          new DescribeStreamSummaryCommand({ StreamName: name }),
        )
        const summary = out.StreamDescriptionSummary
        return {
          name: summary?.StreamName ?? name,
          arn: summary?.StreamARN ?? '',
          status: summary?.StreamStatus ?? '—',
          capacityMode: capacityLabel(summary?.StreamModeDetails?.StreamMode),
          monitoring: 'Open',
          createdOn: summary?.StreamCreationTimestamp,
        } satisfies KinesisStreamRow
      } catch {
        return {
          name,
          arn: '',
          status: '—',
          capacityMode: '—',
          monitoring: 'Open',
          createdOn: undefined,
        } satisfies KinesisStreamRow
      }
    }),
  )
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}
