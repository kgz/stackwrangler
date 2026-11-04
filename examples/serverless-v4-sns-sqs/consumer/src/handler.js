'use strict'

const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3')

// Optional pad (≥2 MB) so S3 PutObject during deploy uses Expect: 100-continue
// (#467). Smoke writes src/pad-blob.js; absent in day-to-day local runs.
// Read the export so esbuild cannot tree-shake the module out of the zip.
try {
  const padBlob = require('./pad-blob')
  exports.__padLen = Buffer.isBuffer(padBlob)
    ? padBlob.length
    : Buffer.byteLength(String(padBlob))
} catch (_) {
  exports.__padLen = 0
}

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
