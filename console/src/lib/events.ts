import {
  CreateEventBusCommand,
  DescribeEventBusCommand,
  DescribeRuleCommand,
  EventBridgeClient,
  ListEventBusesCommand,
  ListRulesCommand,
  ListTargetsByRuleCommand,
  PutRuleCommand,
  type EventBus,
  type Rule,
  type Target,
} from '@aws-sdk/client-eventbridge'
import { emuCreds } from './emu'

export type EventBridgeRuleRow = {
  name: string
  arn: string
  status: string
  eventBusName: string
  type: string
  updatedOn: Date | undefined
}

export type EventBridgeBusRow = {
  name: string
  arn: string
  type: string
  description: string
}

export type EventBridgeRuleDetail = {
  name: string
  arn: string
  status: string
  eventBusName: string
  type: string
  description: string
  eventPattern: string
  scheduleExpression: string
}

export type EventBridgeTargetRow = {
  id: string
  arn: string
}

export type EventBridgeBusDetail = {
  name: string
  arn: string
  type: string
  description: string
}

export type RuleType = 'pattern' | 'schedule'

export type CreateRuleInput = {
  name: string
  description?: string
  eventBusName: string
  state: 'ENABLED' | 'DISABLED'
  ruleType: RuleType
  eventPattern?: string
  scheduleExpression?: string
}

export type CreateEventBusInput = {
  name: string
  description?: string
}

function eventsClient(): EventBridgeClient {
  return new EventBridgeClient(emuCreds())
}

function ruleType(rule: Rule): string {
  if (rule.ScheduleExpression) return 'Schedule'
  return 'Event pattern'
}

function mapRuleRow(rule: Rule): EventBridgeRuleRow {
  const name = rule.Name ?? ''
  return {
    name,
    arn: rule.Arn ?? '',
    status: rule.State ?? '—',
    eventBusName: rule.EventBusName ?? 'default',
    type: ruleType(rule),
    updatedOn: undefined,
  }
}

export async function listRules(): Promise<EventBridgeRuleRow[]> {
  const buses = await listEventBuses()
  const rows: EventBridgeRuleRow[] = []
  for (const bus of buses) {
    const out = await eventsClient().send(
      new ListRulesCommand({ Limit: 100, EventBusName: bus.name }),
    )
    for (const rule of out.Rules ?? []) {
      rows.push(mapRuleRow(rule))
    }
  }
  return rows.sort((a, b) => {
    const byBus = a.eventBusName.localeCompare(b.eventBusName)
    if (byBus !== 0) return byBus
    return a.name.localeCompare(b.name)
  })
}

export async function listEventBuses(): Promise<EventBridgeBusRow[]> {
  const out = await eventsClient().send(
    new ListEventBusesCommand({ Limit: 100 }),
  )
  const rows = (out.EventBuses ?? []).map((bus: EventBus) => {
    const name = bus.Name ?? ''
    const isDefault = name === 'default'
    return {
      name,
      arn: bus.Arn ?? '',
      type: isDefault ? 'Default' : 'Custom',
      description: bus.Description?.trim()
        ? bus.Description
        : isDefault
          ? 'AWS default event bus'
          : '—',
    } satisfies EventBridgeBusRow
  })
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}

export async function describeRule(
  name: string,
  eventBusName = 'default',
): Promise<EventBridgeRuleDetail> {
  const out = await eventsClient().send(
    new DescribeRuleCommand({
      Name: name,
      EventBusName: eventBusName,
    }),
  )
  return {
    name: out.Name ?? name,
    arn: out.Arn ?? '',
    status: out.State ?? '—',
    eventBusName: out.EventBusName ?? eventBusName,
    type: out.ScheduleExpression ? 'Schedule' : 'Event pattern',
    description: out.Description?.trim() ? out.Description : '—',
    eventPattern: out.EventPattern?.trim() ? out.EventPattern : '',
    scheduleExpression: out.ScheduleExpression?.trim()
      ? out.ScheduleExpression
      : '',
  }
}

export async function listRuleTargets(
  name: string,
  eventBusName = 'default',
): Promise<EventBridgeTargetRow[]> {
  const out = await eventsClient().send(
    new ListTargetsByRuleCommand({
      Rule: name,
      EventBusName: eventBusName,
    }),
  )
  return (out.Targets ?? [])
    .map((t: Target) => ({
      id: t.Id ?? '',
      arn: t.Arn ?? '',
    }))
    .filter((t) => t.id || t.arn)
}

export async function describeEventBus(
  name: string,
): Promise<EventBridgeBusDetail> {
  const out = await eventsClient().send(
    new DescribeEventBusCommand({ Name: name }),
  )
  const busName = out.Name ?? name
  const isDefault = busName === 'default'
  return {
    name: busName,
    arn: out.Arn ?? '',
    type: isDefault ? 'Default' : 'Custom',
    description: out.Description?.trim()
      ? out.Description
      : isDefault
        ? 'AWS default event bus'
        : '—',
  }
}

export async function createRule(input: CreateRuleInput): Promise<void> {
  const name = input.name.trim()
  if (!name) throw new Error('Rule name is required')
  const eventBusName = input.eventBusName.trim() || 'default'

  if (input.ruleType === 'schedule') {
    const schedule = input.scheduleExpression?.trim() ?? ''
    if (!schedule) throw new Error('Schedule expression is required')
    await eventsClient().send(
      new PutRuleCommand({
        Name: name,
        Description: input.description?.trim() || undefined,
        EventBusName: eventBusName,
        State: input.state,
        ScheduleExpression: schedule,
      }),
    )
    return
  }

  const pattern = input.eventPattern?.trim() ?? ''
  if (!pattern) throw new Error('Event pattern is required')
  try {
    JSON.parse(pattern)
  } catch {
    throw new Error('Event pattern must be valid JSON')
  }
  await eventsClient().send(
    new PutRuleCommand({
      Name: name,
      Description: input.description?.trim() || undefined,
      EventBusName: eventBusName,
      State: input.state,
      EventPattern: pattern,
    }),
  )
}

export async function createEventBus(input: CreateEventBusInput): Promise<void> {
  const name = input.name.trim()
  if (!name) throw new Error('Event bus name is required')
  if (name === 'default') {
    throw new Error('Cannot create the default event bus')
  }
  await eventsClient().send(
    new CreateEventBusCommand({
      Name: name,
      Description: input.description?.trim() || undefined,
    }),
  )
}
