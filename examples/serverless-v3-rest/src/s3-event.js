export async function handler(event) {
  const n = (event.Records && event.Records.length) || 0
  return { ok: true, action: 's3-event', records: n }
}
