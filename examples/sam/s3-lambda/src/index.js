const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3')

exports.handler = async (event) => {
  const bucket = process.env.BUCKET_NAME
  if (!bucket) {
    throw new Error('BUCKET_NAME not set')
  }

  const key = `writes/${Date.now()}.json`
  const body = JSON.stringify({
    ok: true,
    at: new Date().toISOString(),
    event: event ?? null,
  })

  const client = new S3Client({
    region: process.env.AWS_REGION || 'us-east-1',
    forcePathStyle: true,
  })

  await client.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: body,
      ContentType: 'application/json',
    }),
  )

  return { ok: true, bucket, key }
}
