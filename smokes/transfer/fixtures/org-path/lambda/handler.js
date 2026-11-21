// Org-path ObjectCreated handler (#781).
// Copies inbox object metadata to processed/ so ECS can consume the path brain.
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
  const bucket = process.env.PATH_BUCKET;
  const prefix = process.env.PROCESSED_PREFIX || "processed/";
  if (!bucket || keys.length === 0) {
    return { ok: false, keys };
  }
  const out = [];
  for (const key of keys) {
    const base = key.split("/").pop() || key;
    const dest = `${prefix}${base}.json`;
    const body = JSON.stringify({
      sourceKey: key,
      at: new Date().toISOString(),
      marker: process.env.PATH_MARKER || "",
    });
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: dest,
        Body: body,
        ContentType: "application/json",
      }),
    );
    out.push(dest);
  }
  return { ok: true, keys, processed: out };
};
