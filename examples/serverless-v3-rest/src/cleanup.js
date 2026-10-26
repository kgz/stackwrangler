export async function handler() {
  return { ok: true, action: 'cleanup', table: process.env.TABLE_NAME || '' }
}
