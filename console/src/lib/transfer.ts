import {
  CreateServerCommand,
  DeleteServerCommand,
  DescribeServerCommand,
  DescribeUserCommand,
  ListServersCommand,
  ListUsersCommand,
  TransferClient,
  type DescribedServer,
  type DescribedUser,
  type ListedServer,
  type ListedUser,
} from '@aws-sdk/client-transfer'
import { emuCreds } from './emu'

const STORAGE_KEY = 'awsbox.transfer.serverIds'

function client() {
  return new TransferClient(emuCreds())
}

function rememberedIds(): string[] {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter((x): x is string => typeof x === 'string')
  } catch {
    return []
  }
}

function rememberId(id: string) {
  const next = Array.from(new Set([...rememberedIds(), id]))
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(next))
}

function forgetId(id: string) {
  const next = rememberedIds().filter((x) => x !== id)
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(next))
}

export async function listServers(): Promise<ListedServer[]> {
  const out = await client().send(new ListServersCommand({}))
  const fromApi = out.Servers ?? []
  const seen = new Set(
    fromApi.map((s) => s.ServerId).filter((id): id is string => Boolean(id)),
  )
  const extras: ListedServer[] = []
  for (const id of rememberedIds()) {
    if (seen.has(id)) continue
    try {
      const d = await describeServer(id)
      if (d.ServerId) {
        extras.push({
          ServerId: d.ServerId,
          State: d.State,
          UserCount: d.UserCount,
          IdentityProviderType: d.IdentityProviderType,
        })
      }
    } catch {
      forgetId(id)
    }
  }
  return [...fromApi, ...extras]
}

export async function describeServer(
  serverId: string,
): Promise<DescribedServer> {
  const out = await client().send(
    new DescribeServerCommand({ ServerId: serverId }),
  )
  if (!out.Server) {
    throw new Error(`Server ${serverId} not found`)
  }
  return out.Server
}

export async function createSftpServer(): Promise<string> {
  const out = await client().send(
    new CreateServerCommand({
      Protocols: ['SFTP'],
      IdentityProviderType: 'SERVICE_MANAGED',
    }),
  )
  const id = out.ServerId
  if (!id) throw new Error('CreateServer returned no ServerId')
  rememberId(id)
  return id
}

export async function deleteServer(serverId: string): Promise<void> {
  await client().send(new DeleteServerCommand({ ServerId: serverId }))
  forgetId(serverId)
}

export async function listUsers(serverId: string): Promise<ListedUser[]> {
  const out = await client().send(
    new ListUsersCommand({ ServerId: serverId }),
  )
  return out.Users ?? []
}

export async function describeUser(
  serverId: string,
  userName: string,
): Promise<DescribedUser> {
  const out = await client().send(
    new DescribeUserCommand({ ServerId: serverId, UserName: userName }),
  )
  if (!out.User) {
    throw new Error(`User ${userName} not found`)
  }
  return out.User
}

export type { DescribedServer, DescribedUser, ListedServer, ListedUser }
