const {
  APIGatewayClient,
  CreateApiKeyCommand,
  CreateUsagePlanKeyCommand,
  DeleteApiKeyCommand,
  GetUsagePlansCommand,
} = require("@aws-sdk/client-api-gateway");

const client = new APIGatewayClient({ region: process.env.AWS_REGION || "us-east-1" });

async function findPlan(name) {
  let position;
  do {
    const page = await client.send(new GetUsagePlansCommand({ position, limit: 100 }));
    const plan = (page.items || []).find((p) => p.name === name);
    if (plan) return plan;
    position = page.position;
  } while (position);
  throw new Error(`usage plan not found: ${name}`);
}

// mint: { action: "mint", plan, name } -> { keyId, value }
// revoke: { action: "revoke", keyId }
exports.handler = async (event) => {
  try {
    if (event.action === "mint") {
      const plan = await findPlan(event.plan);
      const key = await client.send(new CreateApiKeyCommand({ name: event.name, enabled: true }));
      await client.send(
        new CreateUsagePlanKeyCommand({ usagePlanId: plan.id, keyId: key.id, keyType: "API_KEY" })
      );
      return { ok: true, keyId: key.id, value: key.value };
    }
    if (event.action === "revoke") {
      await client.send(new DeleteApiKeyCommand({ apiKey: event.keyId }));
      return { ok: true };
    }
    return { ok: false, error: `unknown action ${event.action}` };
  } catch (err) {
    return { ok: false, error: err.name || "Error", message: String(err.message || err) };
  }
};
