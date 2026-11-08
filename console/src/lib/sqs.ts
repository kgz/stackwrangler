import {
  CreateQueueCommand,
  DeleteQueueCommand,
  GetQueueAttributesCommand,
  GetQueueUrlCommand,
  ListQueuesCommand,
  SendMessageCommand,
  SQSClient,
} from '@aws-sdk/client-sqs'
import { emuCreds } from './emu'

export type SqsQueueType = 'Standard' | 'FIFO'

export type SqsQueueRow = {
  name: string
  url: string
  type: SqsQueueType
  createdOn: Date | undefined
  messagesAvailable: string
  messagesInFlight: string
}

export type SqsQueueDetail = {
  name: string
  url: string
  arn: string
  type: SqsQueueType
  createdOn: Date | undefined
  messagesAvailable: string
  messagesInFlight: string
  messagesDelayed: string
  visibilityTimeout: string
  messageRetentionPeriod: string
  delaySeconds: string
  receiveMessageWaitTimeSeconds: string
  maximumMessageSize: string
  fifoQueue: boolean
  contentBasedDeduplication: string | undefined
}

export type CreateQueueInput = {
  name: string
  type: SqsQueueType
  contentBasedDeduplication?: boolean
  visibilityTimeout?: string
  messageRetentionPeriod?: string
  delaySeconds?: string
  receiveMessageWaitTimeSeconds?: string
  maximumMessageSize?: string
}

export type SendQueueMessageInput = {
  queueUrl: string
  body: string
  delaySeconds?: number
  messageGroupId?: string
  messageDeduplicationId?: string
}

function sqsClient(): SQSClient {
  return new SQSClient(emuCreds())
}

function queueNameFromUrl(url: string): string {
  const trimmed = url.replace(/\/$/, '')
  const parts = trimmed.split('/')
  const name = parts[parts.length - 1]
  return name || url
}

function typeFromName(name: string): SqsQueueType {
  return name.endsWith('.fifo') ? 'FIFO' : 'Standard'
}

function typeFromAttrs(
  name: string,
  attrs: Record<string, string>,
): SqsQueueType {
  if (attrs.FifoQueue === 'true') return 'FIFO'
  if (attrs.FifoQueue === 'false') return 'Standard'
  return typeFromName(name)
}

function createdFromAttrs(
  attrs: Record<string, string>,
): Date | undefined {
  const createdRaw = attrs.CreatedTimestamp
  const createdSec = createdRaw ? Number(createdRaw) : NaN
  return Number.isFinite(createdSec)
    ? new Date(createdSec * 1000)
    : undefined
}

async function listQueueUrls(): Promise<string[]> {
  const urls: string[] = []
  let nextToken: string | undefined
  for (;;) {
    const out = await sqsClient().send(
      new ListQueuesCommand({ MaxResults: 1000, NextToken: nextToken }),
    )
    for (const url of out.QueueUrls ?? []) {
      if (url) urls.push(url)
    }
    nextToken = out.NextToken
    if (!nextToken) break
  }
  return urls
}

export async function listQueues(): Promise<SqsQueueRow[]> {
  const urls = await listQueueUrls()
  const rows = await Promise.all(
    urls.map(async (url) => {
      const name = queueNameFromUrl(url)
      try {
        const out = await sqsClient().send(
          new GetQueueAttributesCommand({
            QueueUrl: url,
            AttributeNames: [
              'FifoQueue',
              'CreatedTimestamp',
              'ApproximateNumberOfMessages',
              'ApproximateNumberOfMessagesNotVisible',
            ],
          }),
        )
        const attrs = out.Attributes ?? {}
        return {
          name,
          url,
          type: typeFromAttrs(name, attrs),
          createdOn: createdFromAttrs(attrs),
          messagesAvailable: attrs.ApproximateNumberOfMessages ?? '—',
          messagesInFlight:
            attrs.ApproximateNumberOfMessagesNotVisible ?? '—',
        } satisfies SqsQueueRow
      } catch {
        return {
          name,
          url,
          type: typeFromName(name),
          createdOn: undefined,
          messagesAvailable: '—',
          messagesInFlight: '—',
        } satisfies SqsQueueRow
      }
    }),
  )
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}

export async function getQueueUrl(name: string): Promise<string> {
  const out = await sqsClient().send(
    new GetQueueUrlCommand({ QueueName: name }),
  )
  if (!out.QueueUrl) throw new Error(`Queue URL missing for ${name}`)
  return out.QueueUrl
}

export async function describeQueue(name: string): Promise<SqsQueueDetail> {
  const url = await getQueueUrl(name)
  const out = await sqsClient().send(
    new GetQueueAttributesCommand({
      QueueUrl: url,
      AttributeNames: [
        'QueueArn',
        'FifoQueue',
        'ContentBasedDeduplication',
        'CreatedTimestamp',
        'ApproximateNumberOfMessages',
        'ApproximateNumberOfMessagesNotVisible',
        'ApproximateNumberOfMessagesDelayed',
        'VisibilityTimeout',
        'MaximumMessageSize',
        'MessageRetentionPeriod',
        'DelaySeconds',
        'ReceiveMessageWaitTimeSeconds',
      ],
    }),
  )
  const attrs = out.Attributes ?? {}
  const type = typeFromAttrs(name, attrs)
  return {
    name,
    url,
    arn: attrs.QueueArn ?? '',
    type,
    createdOn: createdFromAttrs(attrs),
    messagesAvailable: attrs.ApproximateNumberOfMessages ?? '—',
    messagesInFlight: attrs.ApproximateNumberOfMessagesNotVisible ?? '—',
    messagesDelayed: attrs.ApproximateNumberOfMessagesDelayed ?? '—',
    visibilityTimeout: attrs.VisibilityTimeout ?? '—',
    messageRetentionPeriod: attrs.MessageRetentionPeriod ?? '—',
    delaySeconds: attrs.DelaySeconds ?? '—',
    receiveMessageWaitTimeSeconds:
      attrs.ReceiveMessageWaitTimeSeconds ?? '—',
    maximumMessageSize: attrs.MaximumMessageSize ?? '—',
    fifoQueue: type === 'FIFO',
    contentBasedDeduplication:
      type === 'FIFO' ? (attrs.ContentBasedDeduplication ?? 'false') : undefined,
  }
}

export async function createQueue(input: CreateQueueInput): Promise<string> {
  const name = input.name.trim()
  if (!name) throw new Error('Queue name is required')

  if (input.type === 'FIFO' && !name.endsWith('.fifo')) {
    throw new Error('FIFO queue names must end with .fifo')
  }
  if (input.type === 'Standard' && name.endsWith('.fifo')) {
    throw new Error('Standard queue names must not end with .fifo')
  }

  const attributes: Record<string, string> = {}
  if (input.type === 'FIFO') {
    attributes.FifoQueue = 'true'
    if (input.contentBasedDeduplication) {
      attributes.ContentBasedDeduplication = 'true'
    }
  }
  if (input.visibilityTimeout != null && input.visibilityTimeout !== '') {
    attributes.VisibilityTimeout = input.visibilityTimeout
  }
  if (
    input.messageRetentionPeriod != null &&
    input.messageRetentionPeriod !== ''
  ) {
    attributes.MessageRetentionPeriod = input.messageRetentionPeriod
  }
  if (input.delaySeconds != null && input.delaySeconds !== '') {
    attributes.DelaySeconds = input.delaySeconds
  }
  if (
    input.receiveMessageWaitTimeSeconds != null &&
    input.receiveMessageWaitTimeSeconds !== ''
  ) {
    attributes.ReceiveMessageWaitTimeSeconds =
      input.receiveMessageWaitTimeSeconds
  }
  if (input.maximumMessageSize != null && input.maximumMessageSize !== '') {
    attributes.MaximumMessageSize = input.maximumMessageSize
  }

  const out = await sqsClient().send(
    new CreateQueueCommand({
      QueueName: name,
      Attributes: Object.keys(attributes).length > 0 ? attributes : undefined,
    }),
  )
  if (!out.QueueUrl) throw new Error('CreateQueue did not return a QueueUrl')
  return out.QueueUrl
}

export async function deleteQueue(queueUrl: string): Promise<void> {
  await sqsClient().send(new DeleteQueueCommand({ QueueUrl: queueUrl }))
}

export async function sendQueueMessage(
  input: SendQueueMessageInput,
): Promise<string | undefined> {
  const body = input.body
  if (!body) throw new Error('Message body is required')

  const out = await sqsClient().send(
    new SendMessageCommand({
      QueueUrl: input.queueUrl,
      MessageBody: body,
      DelaySeconds: input.delaySeconds,
      MessageGroupId: input.messageGroupId,
      MessageDeduplicationId: input.messageDeduplicationId,
    }),
  )
  return out.MessageId
}
