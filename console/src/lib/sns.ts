import {
  GetTopicAttributesCommand,
  ListTopicsCommand,
  SNSClient,
} from '@aws-sdk/client-sns'
import { emuCreds } from './emu'

export type SnsTopicRow = {
  name: string
  arn: string
  type: 'Standard' | 'FIFO'
}

function snsClient(): SNSClient {
  return new SNSClient(emuCreds())
}

function topicNameFromArn(arn: string): string {
  const parts = arn.split(':')
  const name = parts[parts.length - 1]
  return name || arn
}

function typeFromName(name: string): 'Standard' | 'FIFO' {
  return name.endsWith('.fifo') ? 'FIFO' : 'Standard'
}

async function listTopicArns(): Promise<string[]> {
  const arns: string[] = []
  let nextToken: string | undefined
  for (;;) {
    const out = await snsClient().send(
      new ListTopicsCommand({ NextToken: nextToken }),
    )
    for (const t of out.Topics ?? []) {
      if (t.TopicArn) arns.push(t.TopicArn)
    }
    nextToken = out.NextToken
    if (!nextToken) break
  }
  return arns
}

async function topicType(arn: string, name: string): Promise<'Standard' | 'FIFO'> {
  try {
    const out = await snsClient().send(
      new GetTopicAttributesCommand({ TopicArn: arn }),
    )
    const fifo = out.Attributes?.FifoTopic
    if (fifo === 'true') return 'FIFO'
    if (fifo === 'false') return 'Standard'
  } catch {
    // fall through to name heuristic
  }
  return typeFromName(name)
}

export async function listTopics(): Promise<SnsTopicRow[]> {
  const arns = await listTopicArns()
  const rows = await Promise.all(
    arns.map(async (arn) => {
      const name = topicNameFromArn(arn)
      return {
        name,
        arn,
        type: await topicType(arn, name),
      } satisfies SnsTopicRow
    }),
  )
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}
