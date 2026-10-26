const {
  TransferClient,
  CreateConnectorCommand,
  UpdateConnectorCommand,
  TestConnectionCommand,
  StartFileTransferCommand,
  ListFileTransferResultsCommand,
} = require("@aws-sdk/client-transfer");

const transfer = new TransferClient({});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Create a tenant connector, learn the host key, trust it, then verify the connection.
async function onboard(e) {
  const { ConnectorId } = await transfer.send(
    new CreateConnectorCommand({
      Url: e.url,
      AccessRole: e.accessRole,
      LoggingRole: e.loggingRole,
      SftpConfig: { UserSecretId: e.secretId },
      Tags: [{ Key: "tenant", Value: e.tenant }],
    }),
  );
  const probe = await transfer.send(new TestConnectionCommand({ ConnectorId }));
  const hostKey = probe.SftpConnectionDetails && probe.SftpConnectionDetails.HostKey;
  if (!hostKey) return { ok: false, connectorId: ConnectorId, status: probe.Status, message: probe.StatusMessage };
  await transfer.send(
    new UpdateConnectorCommand({
      ConnectorId,
      SftpConfig: { UserSecretId: e.secretId, TrustedHostKeys: [hostKey] },
    }),
  );
  const checked = await transfer.send(new TestConnectionCommand({ ConnectorId }));
  return { ok: checked.Status === "OK", connectorId: ConnectorId, status: checked.Status, message: checked.StatusMessage };
}

async function send(e) {
  const { TransferId } = await transfer.send(
    new StartFileTransferCommand({
      ConnectorId: e.connectorId,
      SendFilePaths: [e.path],
      RemoteDirectoryPath: e.remoteDir,
    }),
  );
  for (let i = 0; i < 30; i++) {
    const { FileTransferResults } = await transfer.send(
      new ListFileTransferResultsCommand({ ConnectorId: e.connectorId, TransferId }),
    );
    const r = FileTransferResults[0];
    if (r && (r.StatusCode === "COMPLETED" || r.StatusCode === "FAILED")) {
      return { ok: r.StatusCode === "COMPLETED", transferId: TransferId, statusCode: r.StatusCode, failure: r.FailureMessage || null };
    }
    await sleep(1000);
  }
  return { ok: false, transferId: TransferId, statusCode: "TIMEOUT" };
}

exports.main = async (event) => {
  try {
    return event.action === "onboard" ? await onboard(event) : await send(event);
  } catch (err) {
    return { ok: false, name: err.name || null, message: String(err.message || err) };
  }
};
