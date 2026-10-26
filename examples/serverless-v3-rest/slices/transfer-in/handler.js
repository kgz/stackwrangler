// S3 ObjectCreated handler for Transfer inbound slice (#141).
// Writes a small marker object so the smoke can prove the event fired.
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");

const s3 = new S3Client({
  region: process.env.AWS_REGION || "us-east-1",
  forcePathStyle: true,
});

exports.main = async (event) => {
  const records = (event && event.Records) || [];
  const keys = records
    .map((r) => (r.s3 && r.s3.object && r.s3.object.key) || "")
    .filter(Boolean)
    .map((k) => decodeURIComponent(String(k).replace(/\+/g, " ")));
  const bucket = process.env.MARKER_BUCKET;
  const markerKey = process.env.MARKER_KEY || "markers/transfer-in.txt";
  if (!bucket || keys.length === 0) {
    return { ok: false, keys };
  }
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: markerKey,
      Body: JSON.stringify({ keys, at: new Date().toISOString() }),
      ContentType: "application/json",
    }),
  );
  return { ok: true, keys };
};
