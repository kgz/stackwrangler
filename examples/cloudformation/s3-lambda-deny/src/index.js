const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3')

exports.handler = async (event) => {
  const bucket = process.env.BUCKET_NAME
  if (!bucket) {
    throw new Error('BUCKET_NAME not set')
  }

  const client = new S3Client({
    region: process.env.AWS_REGION || 'us-east-1',
    forcePathStyle: true,
  })

  try {
    await client.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: 'authz-probe.txt',
        Body: 'should-deny',
      }),
    )
    return { ok: true, wrote: true, bucket }
  } catch (err) {
    return {
      ok: false,
      wrote: false,
      name: err.name || null,
      code: err.Code || err.code || err.$metadata?.httpStatusCode || null,
      message: String(err.message || err),
      event: event ?? null,
    }
  }
}
