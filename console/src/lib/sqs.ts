import {
  GetQueueAttributesCommand,
  ListQueuesCommand,
  SQSClient,
} from '@aws-sdk/client-sqs'
import { emuCreds } from './emu'

function client() {
  return new SQSClient(emuCreds())
}

export type SqsQueue = {
  url: string
  name: string
  arn?: string
}

function queueNameFromUrl(url: string): string {
  const parts = url.replace(/\/$/, '').split('/')
  return parts[parts.length - 1] || url
}

export async function listQueues(): Promise<SqsQueue[]> {
  const out = await client().send(new ListQueuesCommand({}))
  const urls = out.QueueUrls ?? []
  const queues: SqsQueue[] = []
  for (const url of urls) {
    let arn: string | undefined
    try {
      const attrs = await client().send(
        new GetQueueAttributesCommand({
          QueueUrl: url,
          AttributeNames: ['QueueArn'],
        }),
      )
      arn = attrs.Attributes?.QueueArn
    } catch {
      arn = undefined
    }
    queues.push({ url, name: queueNameFromUrl(url), arn })
  }
  return queues
}
