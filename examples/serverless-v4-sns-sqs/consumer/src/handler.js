'use strict'

const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3')

// LocalEmu injects AWS_ENDPOINT_URL into the Lambda container; forcePathStyle
// keeps PutObject on the edge port (virtual-host style is flaky on :4566).
const s3 = new S3Client({
  region: process.env.AWS_REGION || 'us-east-1',
  forcePathStyle: true,
})

exports.handler = async (event) => {
  const bucket = process.env.RESULTS_BUCKET
  if (!bucket) {
    throw new Error('RESULTS_BUCKET unset')
  }
  for (const record of event.Records || []) {
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: `got/${record.messageId}`,
        Body: JSON.stringify({
          body: record.body,
          app: process.env.APP_NAME || '',
          redeploy: process.env.REDEPLOY_MARK || '',
          topic: process.env.TOPIC_ARN || '',
        }),
      }),
    )
  }
  return { ok: true, count: (event.Records || []).length }
}
