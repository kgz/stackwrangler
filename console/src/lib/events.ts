import {
  EventBridgeClient,
  ListEventBusesCommand,
  ListRulesCommand,
  type EventBus,
  type Rule,
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

function eventsClient(): EventBridgeClient {
  return new EventBridgeClient(emuCreds())
}

function ruleType(rule: Rule): string {
  if (rule.ScheduleExpression) return 'Schedule'
  return 'Event pattern'
}

export async function listRules(): Promise<EventBridgeRuleRow[]> {
  const out = await eventsClient().send(
    new ListRulesCommand({ Limit: 100 }),
  )
  const rows = (out.Rules ?? []).map((rule) => {
    const name = rule.Name ?? ''
    return {
      name,
      arn: rule.Arn ?? '',
      status: rule.State ?? '—',
      eventBusName: rule.EventBusName ?? 'default',
      type: ruleType(rule),
      updatedOn: undefined,
    } satisfies EventBridgeRuleRow
  })
  return rows.sort((a, b) => a.name.localeCompare(b.name))
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
