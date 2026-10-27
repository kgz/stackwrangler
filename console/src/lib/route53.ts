import {
  ListHostedZonesCommand,
  ListResourceRecordSetsCommand,
  Route53Client,
  type HostedZone,
  type ResourceRecordSet,
} from '@aws-sdk/client-route-53'
import { emuCreds } from './emu'

function client() {
  return new Route53Client(emuCreds())
}

export async function listHostedZones(): Promise<HostedZone[]> {
  const out = await client().send(new ListHostedZonesCommand({}))
  return out.HostedZones ?? []
}

export async function listResourceRecordSets(
  hostedZoneId: string,
): Promise<ResourceRecordSet[]> {
  const id = hostedZoneId.replace(/^\/hostedzone\//, '')
  const out = await client().send(
    new ListResourceRecordSetsCommand({ HostedZoneId: id }),
  )
  return out.ResourceRecordSets ?? []
}

export type { HostedZone, ResourceRecordSet }
