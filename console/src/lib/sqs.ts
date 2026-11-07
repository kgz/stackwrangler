import {
  GetQueueAttributesCommand,
  ListQueuesCommand,
  SQSClient,
} from '@aws-sdk/client-sqs'
import { emuCreds } from './emu'

export type SqsQueueRow = {
  name: string
  url: string
  type: 'Standard' | 'FIFO'
  createdOn: Date | undefined
  messagesAvailable: string
  messagesInFlight: string
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

function typeFromName(name: string): 'Standard' | 'FIFO' {
  return name.endsWith('.fifo') ? 'FIFO' : 'Standard'
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
        const createdRaw = attrs.CreatedTimestamp
        const createdSec = createdRaw ? Number(createdRaw) : NaN
        return {
          name,
          url,
          type:
            attrs.FifoQueue === 'true'
              ? 'FIFO'
              : attrs.FifoQueue === 'false'
                ? 'Standard'
                : typeFromName(name),
          createdOn: Number.isFinite(createdSec)
            ? new Date(createdSec * 1000)
            : undefined,
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
