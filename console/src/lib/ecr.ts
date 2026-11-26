import {
  DescribeImagesCommand,
  DescribeRepositoriesCommand,
  ECRClient,
  type ImageDetail,
  type Repository,
} from '@aws-sdk/client-ecr'
import { emuCreds } from './emu'

export type EcrRepositoryRow = {
  name: string
  uri: string
  arn: string
  registryId: string
  createdAt: Date | undefined
  imageTagMutability: string
  scanOnPush: string
  encryptionType: string
}

export type EcrImageRow = {
  tag: string
  digest: string
  pushedAt: Date | undefined
}

function ecrClient(): ECRClient {
  return new ECRClient(emuCreds())
}

function mutabilityLabel(raw: string | undefined): string {
  if (!raw) return '—'
  if (raw === 'MUTABLE') return 'Mutable'
  if (raw === 'IMMUTABLE') return 'Immutable'
  return raw
}

function scanLabel(repo: Repository): string {
  const scan = repo.imageScanningConfiguration?.scanOnPush
  if (scan === true) return 'Enabled'
  if (scan === false) return 'Disabled'
  return '—'
}

function encryptionLabel(repo: Repository): string {
  const enc = repo.encryptionConfiguration?.encryptionType
  if (!enc) return 'AES256'
  return enc
}

function scanDetailLabel(repo: Repository): string {
  const scan = repo.imageScanningConfiguration?.scanOnPush
  if (scan === true) return 'Scan on push'
  if (scan === false) return 'Manual'
  return '—'
}

function toRow(repo: Repository): EcrRepositoryRow | null {
  const name = repo.repositoryName
  if (!name) return null
  return {
    name,
    uri: repo.repositoryUri ?? '—',
    arn: repo.repositoryArn ?? '—',
    registryId: repo.registryId ?? '—',
    createdAt: repo.createdAt,
    imageTagMutability: mutabilityLabel(repo.imageTagMutability),
    scanOnPush: scanLabel(repo),
    encryptionType: encryptionLabel(repo),
  }
}

export async function listRepositories(): Promise<EcrRepositoryRow[]> {
  const rows: EcrRepositoryRow[] = []
  let nextToken: string | undefined
  for (;;) {
    const out = await ecrClient().send(
      new DescribeRepositoriesCommand({
        maxResults: 100,
        nextToken,
      }),
    )
    for (const repo of out.repositories ?? []) {
      const row = toRow(repo)
      if (row) rows.push(row)
    }
    nextToken = out.nextToken
    if (!nextToken) break
  }
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}

export async function describeRepository(
  name: string,
): Promise<EcrRepositoryRow & { scanDetail: string }> {
  const out = await ecrClient().send(
    new DescribeRepositoriesCommand({ repositoryNames: [name] }),
  )
  const repo = out.repositories?.[0]
  if (!repo) throw new Error(`Repository not found: ${name}`)
  const row = toRow(repo)
  if (!row) throw new Error(`Repository not found: ${name}`)
  return { ...row, scanDetail: scanDetailLabel(repo) }
}

function imageTag(detail: ImageDetail): string {
  const tags = detail.imageTags ?? []
  if (tags.length === 0) return '—'
  return tags.join(', ')
}

export async function listRepositoryImages(
  repositoryName: string,
): Promise<EcrImageRow[]> {
  const rows: EcrImageRow[] = []
  let nextToken: string | undefined
  for (;;) {
    const out = await ecrClient().send(
      new DescribeImagesCommand({
        repositoryName,
        maxResults: 100,
        nextToken,
      }),
    )
    for (const img of out.imageDetails ?? []) {
      rows.push({
        tag: imageTag(img),
        digest: img.imageDigest ?? '—',
        pushedAt: img.imagePushedAt,
      })
    }
    nextToken = out.nextToken
    if (!nextToken) break
  }
  rows.sort((a, b) => {
    const at = a.pushedAt?.getTime() ?? 0
    const bt = b.pushedAt?.getTime() ?? 0
    return bt - at
  })
  return rows
}
