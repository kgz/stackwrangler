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
): Promise<void> {
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: body,
    }),
  )
}

export async function getObjectBlob(bucket: string, key: string): Promise<Blob> {
  const out = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }))
  const body = out.Body
  if (!body) {
    throw new Error('Empty object body')
  }
  return body.transformToByteArray().then((bytes) => new Blob([bytes]))
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
