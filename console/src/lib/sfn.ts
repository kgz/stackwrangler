import {
  ListStateMachinesCommand,
  SFNClient,
  type StateMachineListItem,
} from '@aws-sdk/client-sfn'
import { emuCreds } from './emu'

function sfnClient(): SFNClient {
  return new SFNClient(emuCreds())
}

export async function listStateMachines(): Promise<StateMachineListItem[]> {
  const out = await sfnClient().send(
    new ListStateMachinesCommand({ maxResults: 100 }),
  )
  return out.stateMachines ?? []
}

export type { StateMachineListItem }
