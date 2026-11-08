import {
  CreateTopicCommand,
  GetTopicAttributesCommand,
  ListSubscriptionsByTopicCommand,
  ListTopicsCommand,
  PublishCommand,
  SNSClient,
} from '@aws-sdk/client-sns'
import { emuCreds } from './emu'

export type SnsTopicRow = {
  name: string
  arn: string
  type: 'Standard' | 'FIFO'
}

export type SnsTopicDetail = {
  name: string
  arn: string
  type: 'Standard' | 'FIFO'
  displayName: string
  owner: string
}

export type SnsSubscriptionRow = {
  protocol: string
  endpoint: string
  status: string
  subscriptionArn: string
}

export type TopicType = 'standard' | 'fifo'

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

function typeFromAttrs(
  attrs: Record<string, string> | undefined,
  name: string,
): 'Standard' | 'FIFO' {
  const fifo = attrs?.FifoTopic
  if (fifo === 'true') return 'FIFO'
  if (fifo === 'false') return 'Standard'
  return typeFromName(name)
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

async function topicType(
  arn: string,
  name: string,
): Promise<'Standard' | 'FIFO'> {
  try {
    const out = await snsClient().send(
      new GetTopicAttributesCommand({ TopicArn: arn }),
    )
    return typeFromAttrs(out.Attributes, name)
  } catch {
    return typeFromName(name)
  }
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

export async function findTopicArnByName(
  name: string,
): Promise<string | undefined> {
  const want = name.trim()
  if (!want) return undefined
  const arns = await listTopicArns()
  return arns.find((arn) => topicNameFromArn(arn) === want)
}

export async function describeTopic(arn: string): Promise<SnsTopicDetail> {
  const out = await snsClient().send(
    new GetTopicAttributesCommand({ TopicArn: arn }),
  )
  const attrs = out.Attributes ?? {}
  const name = topicNameFromArn(attrs.TopicArn ?? arn)
  return {
    name,
    arn: attrs.TopicArn ?? arn,
    type: typeFromAttrs(attrs, name),
    displayName: attrs.DisplayName?.trim() ? attrs.DisplayName : '—',
    owner: attrs.Owner?.trim() ? attrs.Owner : '—',
  }
}

export async function listTopicSubscriptions(
  topicArn: string,
): Promise<SnsSubscriptionRow[]> {
  const rows: SnsSubscriptionRow[] = []
  let nextToken: string | undefined
  for (;;) {
    const out = await snsClient().send(
      new ListSubscriptionsByTopicCommand({
        TopicArn: topicArn,
        NextToken: nextToken,
      }),
    )
    for (const s of out.Subscriptions ?? []) {
      const subArn = s.SubscriptionArn ?? ''
      const pending = !subArn || subArn === 'PendingConfirmation'
      rows.push({
        protocol: s.Protocol ?? '—',
        endpoint: s.Endpoint ?? '—',
        status: pending ? 'Pending confirmation' : 'Confirmed',
        subscriptionArn: pending ? 'PendingConfirmation' : subArn,
      })
    }
    nextToken = out.NextToken
    if (!nextToken) break
  }
  return rows
}

export type CreateTopicInput = {
  name: string
  type: TopicType
  displayName?: string
}

export async function createTopic(input: CreateTopicInput): Promise<string> {
  const name = input.name.trim()
  if (!name) throw new Error('Topic name is required')
  if (input.type === 'fifo' && !name.endsWith('.fifo')) {
    throw new Error('FIFO topic names must end with .fifo')
  }
  if (input.type === 'standard' && name.endsWith('.fifo')) {
    throw new Error('Standard topic names must not end with .fifo')
  }

  const attributes: Record<string, string> = {}
  if (input.type === 'fifo') {
    attributes.FifoTopic = 'true'
  }
  const display = input.displayName?.trim()
  if (display) {
    attributes.DisplayName = display
  }

  const out = await snsClient().send(
    new CreateTopicCommand({
      Name: name,
      Attributes: Object.keys(attributes).length > 0 ? attributes : undefined,
    }),
  )
  const arn = out.TopicArn
  if (!arn) throw new Error('CreateTopic returned no TopicArn')
  return arn
}

export type PublishTopicInput = {
  topicArn: string
  message: string
  subject?: string
  messageGroupId?: string
  messageDeduplicationId?: string
}

export async function publishToTopic(
  input: PublishTopicInput,
): Promise<string> {
  const message = input.message.trim()
  if (!message) throw new Error('Message is required')
  const out = await snsClient().send(
    new PublishCommand({
      TopicArn: input.topicArn,
      Message: message,
      Subject: input.subject?.trim() || undefined,
      MessageGroupId: input.messageGroupId?.trim() || undefined,
      MessageDeduplicationId:
        input.messageDeduplicationId?.trim() || undefined,
    }),
  )
  return out.MessageId ?? ''
}
