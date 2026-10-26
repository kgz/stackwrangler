import {
  CreateBucketCommand,
  DeleteBucketCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  HeadBucketCommand,
  ListBucketsCommand,
  ListObjectsV2Command,
  PutObjectCommand,
  S3Client,
  type _Object,
  type Bucket,
} from '@aws-sdk/client-s3'
import { config } from './config'

export type S3Bucket = Bucket
export type S3Object = _Object

export const s3 = new S3Client({
  region: config.region,
  endpoint: config.endpoint,
  forcePathStyle: true,
  credentials: {
    accessKeyId: config.accessKeyId,
    secretAccessKey: config.secretAccessKey,
  },
  // SeaweedFS / local S3 often reject flexible checksum headers
  requestChecksumCalculation: 'WHEN_REQUIRED',
  responseChecksumValidation: 'WHEN_REQUIRED',
})

export function formatS3Error(err: unknown): string {
  if (err && typeof err === 'object') {
    const rec = err
    const name = 'name' in rec && typeof rec.name === 'string' ? rec.name : ''
    const message =
      'message' in rec && typeof rec.message === 'string' ? rec.message : ''
    if (name && message) return `${name}: ${message}`
    if (message) return message
  }
  return String(err)
}

export async function listBuckets(): Promise<S3Bucket[]> {
  const out = await s3.send(new ListBucketsCommand({}))
  return out.Buckets ?? []
}

export async function createBucket(name: string): Promise<void> {
  await s3.send(new CreateBucketCommand({ Bucket: name }))
}

export async function deleteBucket(name: string): Promise<void> {
  await s3.send(new DeleteBucketCommand({ Bucket: name }))
}

export async function listObjects(bucket: string): Promise<S3Object[]> {
  const out = await s3.send(new ListObjectsV2Command({ Bucket: bucket }))
  return out.Contents ?? []
}

export async function putObject(
  bucket: string,
  key: string,
  body: Blob | ArrayBuffer | string,
  contentType?: string,
): Promise<void> {
  const type =
    contentType ||
    (typeof Blob !== 'undefined' && body instanceof Blob && body.type
      ? body.type
      : guessContentType(key))
  const payload =
    body instanceof ArrayBuffer ? new Uint8Array(body) : body
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: payload,
      ContentType: type || undefined,
    }),
  )
}

export type ObjectPayload = {
  blob: Blob
  contentType: string
  contentLength: number
}

export async function getObject(
  bucket: string,
  key: string,
): Promise<ObjectPayload> {
  const out = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }))
  const body = out.Body
  if (!body) {
    throw new Error('Empty object body')
  }
  const bytes = await body.transformToByteArray()
  const contentType = out.ContentType || guessContentType(key)
  return {
    blob: new Blob([bytes], { type: contentType }),
    contentType,
    contentLength: out.ContentLength ?? bytes.byteLength,
  }
}

export async function getObjectBlob(bucket: string, key: string): Promise<Blob> {
  const payload = await getObject(bucket, key)
  return payload.blob
}

function guessContentType(key: string): string {
  const ext = key.includes('.') ? key.slice(key.lastIndexOf('.') + 1).toLowerCase() : ''
  switch (ext) {
    case 'txt':
    case 'log':
    case 'md':
    case 'csv':
    case 'tsv':
      return 'text/plain'
    case 'json':
      return 'application/json'
    case 'xml':
    case 'svg':
      return ext === 'svg' ? 'image/svg+xml' : 'application/xml'
    case 'html':
    case 'htm':
      return 'text/html'
    case 'js':
    case 'mjs':
    case 'cjs':
      return 'text/javascript'
    case 'css':
      return 'text/css'
    case 'yml':
    case 'yaml':
      return 'text/yaml'
    case 'png':
      return 'image/png'
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg'
    case 'gif':
      return 'image/gif'
    case 'webp':
      return 'image/webp'
    default:
      return 'application/octet-stream'
  }
}

export type PreviewKind = 'text' | 'image' | 'binary'

export function previewKind(contentType: string, key: string): PreviewKind {
  const ct = contentType.toLowerCase()
  if (ct.startsWith('image/') && !ct.includes('svg')) return 'image'
  if (ct === 'image/svg+xml') return 'image'
  if (
    ct.startsWith('text/') ||
    ct.includes('json') ||
    ct.includes('xml') ||
    ct.includes('javascript') ||
    ct.includes('yaml')
  ) {
    return 'text'
  }
  const ext = objectTypeFromKey(key)
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].includes(ext)) return 'image'
  if (
    [
      'txt',
      'log',
      'md',
      'csv',
      'tsv',
      'json',
      'xml',
      'html',
      'htm',
      'js',
      'css',
      'yml',
      'yaml',
    ].includes(ext)
  ) {
    return 'text'
  }
  return 'binary'
}

function objectTypeFromKey(key: string): string {
  const i = key.lastIndexOf('.')
  if (i < 0 || i === key.length - 1) return ''
  return key.slice(i + 1).toLowerCase()
}

export async function deleteObject(bucket: string, key: string): Promise<void> {
  await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }))
}

export async function headBucket(bucket: string): Promise<void> {
  await s3.send(new HeadBucketCommand({ Bucket: bucket }))
}

/** Delete every object (paginated), then the bucket. */
export async function emptyAndDeleteBucket(bucket: string): Promise<void> {
  await emptyBucket(bucket)
  await deleteBucket(bucket)
}

export async function emptyBucket(bucket: string): Promise<number> {
  let deleted = 0
  let token: string | undefined
  do {
    const page = await s3.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        ContinuationToken: token,
      }),
    )
    for (const obj of page.Contents ?? []) {
      if (!obj.Key) continue
      await deleteObject(bucket, obj.Key)
      deleted += 1
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined
  } while (token)
  return deleted
}

export function summarizeObjects(objects: S3Object[]): {
  count: number
  totalBytes: number
} {
  let totalBytes = 0
  for (const o of objects) {
    totalBytes += o.Size ?? 0
  }
  return { count: objects.length, totalBytes }
}
