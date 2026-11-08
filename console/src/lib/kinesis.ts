import {
  AddTagsToStreamCommand,
  CreateStreamCommand,
  DecreaseStreamRetentionPeriodCommand,
  DeleteStreamCommand,
  DescribeStreamSummaryCommand,
  EncryptionType,
  IncreaseStreamRetentionPeriodCommand,
  KinesisClient,
  ListShardsCommand,
  ListStreamsCommand,
  ListTagsForStreamCommand,
  PutRecordCommand,
  PutRecordsCommand,
  RemoveTagsFromStreamCommand,
  StartStreamEncryptionCommand,
  StopStreamEncryptionCommand,
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
  keyId: string | undefined
  createdOn: Date | undefined
}

export type KinesisShardRow = {
  shardId: string
  startingHashKey: string
  endingHashKey: string
  startingSequenceNumber: string
}

export type KinesisTag = {
  key: string
  value: string
}

export type CapacityMode = 'PROVISIONED' | 'ON_DEMAND'
export type EncryptionChoice = 'NONE' | 'KMS'

const DEFAULT_RETENTION_HOURS = 24
const DEFAULT_KMS_KEY = 'alias/aws/kinesis'

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
    keyId: summary?.KeyId,
    createdOn: summary?.StreamCreationTimestamp,
  }
}

export async function waitStreamActive(
  name: string,
  attempts = 60,
): Promise<void> {
  for (let i = 0; i < attempts; i++) {
    const detail = await describeDataStream(name)
    if (detail.status === 'ACTIVE') return
    await new Promise((r) => setTimeout(r, 500))
  }
  throw new Error(`Stream ${name} did not become ACTIVE`)
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
  retentionPeriodHours?: number
  encryption?: EncryptionChoice
  encryptionKeyId?: string
  tags?: KinesisTag[]
}

function encodeUtf8(text: string): Uint8Array {
  return new TextEncoder().encode(text)
}

function normalizeTags(tags: KinesisTag[] | undefined): Record<string, string> {
  const out: Record<string, string> = {}
  for (const t of tags ?? []) {
    const key = t.key.trim()
    if (!key) continue
    out[key] = t.value
  }
  return out
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
  } else {
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

  await waitStreamActive(name)

  const retention = input.retentionPeriodHours
  if (
    retention != null &&
    Number.isFinite(retention) &&
    retention !== DEFAULT_RETENTION_HOURS
  ) {
    await setRetentionPeriod(name, retention, DEFAULT_RETENTION_HOURS)
    await waitStreamActive(name)
  }

  if (input.encryption === 'KMS') {
    await startStreamEncryption(
      name,
      input.encryptionKeyId?.trim() || DEFAULT_KMS_KEY,
    )
    await waitStreamActive(name)
  }

  const tagMap = normalizeTags(input.tags)
  if (Object.keys(tagMap).length > 0) {
    await addStreamTags(name, tagMap)
  }
}

export async function deleteDataStream(name: string): Promise<void> {
  await kinesisClient().send(
    new DeleteStreamCommand({
      StreamName: name,
      EnforceConsumerDeletion: true,
    }),
  )
}

export async function putRecord(
  name: string,
  partitionKey: string,
  data: string,
): Promise<{ sequenceNumber: string; shardId: string }> {
  const pk = partitionKey.trim()
  if (!pk) throw new Error('Partition key is required')
  const out = await kinesisClient().send(
    new PutRecordCommand({
      StreamName: name,
      PartitionKey: pk,
      Data: encodeUtf8(data),
    }),
  )
  return {
    sequenceNumber: out.SequenceNumber ?? '',
    shardId: out.ShardId ?? '',
  }
}

export async function putRecords(
  name: string,
  records: Array<{ partitionKey: string; data: string }>,
): Promise<{ failedCount: number }> {
  if (records.length === 0) throw new Error('At least one record is required')
  const out = await kinesisClient().send(
    new PutRecordsCommand({
      StreamName: name,
      Records: records.map((r) => ({
        PartitionKey: r.partitionKey.trim(),
        Data: encodeUtf8(r.data),
      })),
    }),
  )
  return { failedCount: out.FailedRecordCount ?? 0 }
}

export async function setRetentionPeriod(
  name: string,
  hours: number,
  currentHours: number | undefined,
): Promise<void> {
  const target = Math.floor(hours)
  if (!Number.isFinite(target) || target < 24 || target > 8760) {
    throw new Error('Retention must be between 24 and 8760 hours')
  }
  const current = currentHours ?? DEFAULT_RETENTION_HOURS
  if (target === current) return
  if (target > current) {
    await kinesisClient().send(
      new IncreaseStreamRetentionPeriodCommand({
        StreamName: name,
        RetentionPeriodHours: target,
      }),
    )
    return
  }
  await kinesisClient().send(
    new DecreaseStreamRetentionPeriodCommand({
      StreamName: name,
      RetentionPeriodHours: target,
    }),
  )
}

export async function startStreamEncryption(
  name: string,
  keyId: string,
): Promise<void> {
  const key = keyId.trim() || DEFAULT_KMS_KEY
  await kinesisClient().send(
    new StartStreamEncryptionCommand({
      StreamName: name,
      EncryptionType: EncryptionType.KMS,
      KeyId: key,
    }),
  )
}

export async function stopStreamEncryption(
  name: string,
  keyId: string | undefined,
): Promise<void> {
  await kinesisClient().send(
    new StopStreamEncryptionCommand({
      StreamName: name,
      EncryptionType: EncryptionType.KMS,
      KeyId: keyId?.trim() || DEFAULT_KMS_KEY,
    }),
  )
}

export async function setStreamEncryption(
  name: string,
  encryption: EncryptionChoice,
  keyId: string | undefined,
  currentKeyId: string | undefined,
): Promise<void> {
  if (encryption === 'KMS') {
    await startStreamEncryption(name, keyId || DEFAULT_KMS_KEY)
    return
  }
  await stopStreamEncryption(name, currentKeyId || keyId || DEFAULT_KMS_KEY)
}

export async function listStreamTags(name: string): Promise<KinesisTag[]> {
  const out = await kinesisClient().send(
    new ListTagsForStreamCommand({ StreamName: name }),
  )
  return (out.Tags ?? [])
    .filter((t) => t.Key)
    .map((t) => ({ key: t.Key ?? '', value: t.Value ?? '' }))
    .sort((a, b) => a.key.localeCompare(b.key))
}

export async function addStreamTags(
  name: string,
  tags: Record<string, string>,
): Promise<void> {
  if (Object.keys(tags).length === 0) return
  await kinesisClient().send(
    new AddTagsToStreamCommand({
      StreamName: name,
      Tags: tags,
    }),
  )
}

export async function removeStreamTags(
  name: string,
  keys: string[],
): Promise<void> {
  const cleaned = keys.map((k) => k.trim()).filter(Boolean)
  if (cleaned.length === 0) return
  await kinesisClient().send(
    new RemoveTagsFromStreamCommand({
      StreamName: name,
      TagKeys: cleaned,
    }),
  )
}

export { DEFAULT_RETENTION_HOURS, DEFAULT_KMS_KEY }
