import {
  CreateStreamCommand,
  DeleteStreamCommand,
  DescribeStreamSummaryCommand,
  KinesisClient,
  ListShardsCommand,
  ListStreamsCommand,
  StreamMode,
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

export type KinesisStreamDetail = {
  name: string
  arn: string
  status: string
  capacityMode: string
  openShardCount: number | undefined
  retentionPeriodHours: number | undefined
  encryptionType: string
  createdOn: Date | undefined
}

export type KinesisShardRow = {
  shardId: string
  startingHashKey: string
  endingHashKey: string
  startingSequenceNumber: string
}

export type CapacityMode = 'PROVISIONED' | 'ON_DEMAND'

function kinesisClient(): KinesisClient {
  return new KinesisClient(emuCreds())
}

export function capacityLabel(mode: string | undefined): string {
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

export async function describeDataStream(
  name: string,
): Promise<KinesisStreamDetail> {
  const out = await kinesisClient().send(
    new DescribeStreamSummaryCommand({ StreamName: name }),
  )
  const summary = out.StreamDescriptionSummary
  return {
    name: summary?.StreamName ?? name,
    arn: summary?.StreamARN ?? '',
    status: summary?.StreamStatus ?? '—',
    capacityMode: capacityLabel(summary?.StreamModeDetails?.StreamMode),
    openShardCount: summary?.OpenShardCount,
    retentionPeriodHours: summary?.RetentionPeriodHours,
    encryptionType: summary?.EncryptionType ?? 'NONE',
    createdOn: summary?.StreamCreationTimestamp,
  }
}

export async function listStreamShards(
  name: string,
): Promise<KinesisShardRow[]> {
  const out = await kinesisClient().send(
    new ListShardsCommand({ StreamName: name, MaxResults: 100 }),
  )
  return (out.Shards ?? []).map((s) => ({
    shardId: s.ShardId ?? '—',
    startingHashKey: s.HashKeyRange?.StartingHashKey ?? '—',
    endingHashKey: s.HashKeyRange?.EndingHashKey ?? '—',
    startingSequenceNumber:
      s.SequenceNumberRange?.StartingSequenceNumber ?? '—',
  }))
}

export type CreateDataStreamInput = {
  name: string
  capacityMode: CapacityMode
  shardCount: number
}

export async function createDataStream(
  input: CreateDataStreamInput,
): Promise<void> {
  const name = input.name.trim()
  if (!name) throw new Error('Data stream name is required')

  if (input.capacityMode === 'ON_DEMAND') {
    await kinesisClient().send(
      new CreateStreamCommand({
        StreamName: name,
        StreamModeDetails: { StreamMode: StreamMode.ON_DEMAND },
      }),
    )
    return
  }

  const shards = Math.floor(input.shardCount)
  if (!Number.isFinite(shards) || shards < 1) {
    throw new Error('Shard count must be at least 1')
  }
  await kinesisClient().send(
    new CreateStreamCommand({
      StreamName: name,
      ShardCount: shards,
      StreamModeDetails: { StreamMode: StreamMode.PROVISIONED },
    }),
  )
}

export async function deleteDataStream(name: string): Promise<void> {
  await kinesisClient().send(
    new DeleteStreamCommand({
      StreamName: name,
      EnforceConsumerDeletion: true,
    }),
  )
}
