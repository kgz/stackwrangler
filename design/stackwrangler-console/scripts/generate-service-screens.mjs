import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const screensDir = path.join(root, "screens");
fs.mkdirSync(screensDir, { recursive: true });

function pageShell({ title, page, nav, crumb, service, serviceTitle, main }) {
  const svcTitle = serviceTitle || title;
  return `<!doctype html>
<html lang="en" data-asset-base="../assets">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${title} — ${svcTitle}</title>
  <link rel="stylesheet" href="../assets/fonts.css" />
  <link rel="stylesheet" href="../assets/console.css" />
</head>
<body data-page="${page}" data-nav="${nav}" data-service="${service}" data-title="${title}" data-crumb="${crumb}">
  <div id="aws-chrome"></div>
  <div class="aws-shell" id="aws-shell" data-od-id="shell">
    <main class="aws-main" id="content" data-od-id="main-content">
${main}
    </main>
  </div>
  <script src="../assets/console.js"></script>
</body>
</html>
`;
}

function th(label, { sort, filter } = {}) {
  const sortMark = sort ? ` <span aria-hidden="true">↑</span>` : "";
  const filterBtn = filter
    ? ` <button type="button" class="filter" aria-label="Filter ${label}" title="To implement" disabled aria-disabled="true">▾</button>`
    : "";
  return `<th scope="col"><span class="th-inner">${label}${sortMark}${filterBtn}</span></th>`;
}

function checkTh() {
  return `<th class="check" scope="col"><input type="checkbox" aria-label="Select all" /></th>`;
}

function pager() {
  return `<div class="aws-pager" data-od-id="pagination">
              <button type="button" disabled aria-label="Previous">‹</button>
              <span class="page">1</span>
              <button type="button" disabled aria-label="Next">›</button>
              <button type="button" class="btn-icon" aria-label="Table settings" title="To implement" disabled aria-disabled="true">⚙</button>
            </div>`;
}

function findField(placeholder, id) {
  return `<label class="aws-find"><span aria-hidden="true">⌕</span>
              <input type="search" placeholder="${placeholder}" data-find-table="#data-table" aria-label="${placeholder}"${
                id ? ` data-od-id="${id}"` : ""
              } />
            </label>`;
}

function refreshBtn() {
  return `<button type="button" class="btn-icon" aria-label="Refresh" title="To implement" disabled aria-disabled="true">↻</button>`;
}

function status(kind, label) {
  return `<span class="aws-status aws-status-${kind}">${label}</span>`;
}

function linkCell(href, text, odId) {
  return `<a href="${href}" data-od-id="${odId}">${text}</a>`;
}

function emptyListMain({
  title,
  desc,
  createLabel,
  createId,
  emptyHeading,
  emptyCopy,
  emptyLink,
  filledHref,
}) {
  return `
      <h1 class="aws-h1" data-od-id="page-title">${title}</h1>
      ${desc ? `<p class="aws-desc">${desc}</p>` : ""}
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="${createId}" disabled aria-disabled="true" title="To implement">${createLabel}</button>
          </div>
          <div class="aws-empty-panel" data-od-id="empty-state">
            <strong>${emptyHeading}</strong>
            <p>${emptyCopy}</p>
            <p class="aws-desc" style="margin-top:12px"><a href="${filledHref}">View sample rows</a>${
              emptyLink ? ` · <a href="${emptyLink}">Empty state</a>` : ""
            }</p>
          </div>
        </div>
      </section>`;
}

const pages = [];

pages.push({
  file: "iam-users.html",
  title: "Users",
  page: "iam-users",
  nav: "iam-users",
  crumb: "Users",
  service: "iam",
  serviceTitle: "IAM",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Users</h1>
      <p class="aws-desc">An IAM user is an identity with long-term credentials used to interact with awsbox.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-delete-user" title="Select a row">Delete</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-user" title="To implement" disabled aria-disabled="true">Create user</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search users", "find-users")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="iam-users-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("User name", { sort: true })}
                  ${th("Groups", { filter: true })}
                  ${th("Last activity", { filter: true })}
                  ${th("Password age", { filter: true })}
                  ${th("MFA", { filter: true })}
                  ${th("Access key age", { filter: true })}
                  ${th("Console last sign-in", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="alice">
                  <td class="check"><input type="checkbox" aria-label="Select alice" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="user-alice">alice</button></td>
                  <td>admins</td>
                  <td>2 days ago</td>
                  <td>90 days</td>
                  <td>Assigned</td>
                  <td>12 days</td>
                  <td>2 days ago</td>
                </tr>
                <tr data-name="deploy-bot">
                  <td class="check"><input type="checkbox" aria-label="Select deploy-bot" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="user-deploy-bot">deploy-bot</button></td>
                  <td>ci</td>
                  <td>Never</td>
                  <td>None</td>
                  <td>Not assigned</td>
                  <td>3 days</td>
                  <td>None</td>
                </tr>
                <tr data-name="lab-reader">
                  <td class="check"><input type="checkbox" aria-label="Select lab-reader" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="user-lab-reader">lab-reader</button></td>
                  <td>—</td>
                  <td>14 days ago</td>
                  <td>30 days</td>
                  <td>Not assigned</td>
                  <td>None</td>
                  <td>14 days ago</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "lambda-functions.html",
  title: "Functions",
  page: "lambda-functions",
  nav: "lambda-functions",
  crumb: "Functions",
  service: "lambda",
  serviceTitle: "Lambda",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Functions</h1>
      <p class="aws-desc">Lambda lets you run code without provisioning or managing servers.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-actions" title="Select a row">Actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-function" title="To implement" disabled aria-disabled="true">Create function</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Filter by function name or ARN", "find-functions")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="lambda-functions-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Function name", { sort: true })}
                  ${th("Description", { filter: true })}
                  ${th("Package type", { filter: true })}
                  ${th("Runtime", { filter: true })}
                  ${th("Last modified", { sort: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="awsbox-hello">
                  <td class="check"><input type="checkbox" aria-label="Select awsbox-hello" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="fn-hello">awsbox-hello</button></td>
                  <td>Sample hello handler</td>
                  <td>Zip</td>
                  <td>nodejs20.x</td>
                  <td>2026-10-20 09:14:02</td>
                </tr>
                <tr data-name="orders-ingest">
                  <td class="check"><input type="checkbox" aria-label="Select orders-ingest" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="fn-orders">orders-ingest</button></td>
                  <td>—</td>
                  <td>Zip</td>
                  <td>python3.12</td>
                  <td>2026-10-18 16:02:41</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "logs-log-groups.html",
  title: "Log groups",
  page: "logs-log-groups",
  nav: "logs-log-groups",
  crumb: "Log groups",
  service: "logs",
  serviceTitle: "CloudWatch",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Log groups</h1>
      <p class="aws-desc">A log group is a group of log streams that share the same retention, monitoring, and access control settings.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-actions" title="Select a row">Actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-log-group" title="To implement" disabled aria-disabled="true">Create log group</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Filter log groups", "find-log-groups")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="log-groups-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Log group", { sort: true })}
                  ${th("Retention", { filter: true })}
                  ${th("Stored bytes", { sort: true })}
                  ${th("Metric filters", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="/aws/lambda/awsbox-hello">
                  <td class="check"><input type="checkbox" aria-label="Select /aws/lambda/awsbox-hello" /></td>
                  <td><code class="aws-mono"><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="lg-hello">/aws/lambda/awsbox-hello</button></code></td>
                  <td>Never expire</td>
                  <td>128.4 KB</td>
                  <td>0</td>
                </tr>
                <tr data-name="/aws/lambda/orders-ingest">
                  <td class="check"><input type="checkbox" aria-label="Select /aws/lambda/orders-ingest" /></td>
                  <td><code class="aws-mono"><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="lg-orders">/aws/lambda/orders-ingest</button></code></td>
                  <td>14 days</td>
                  <td>2.1 MB</td>
                  <td>1</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "apigateway-http-apis.html",
  title: "HTTP APIs",
  page: "apigateway-http-apis",
  nav: "apigateway-http-apis",
  crumb: "HTTP APIs",
  service: "apigateway",
  serviceTitle: "API Gateway",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">APIs</h1>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-tabs" role="tablist" data-od-id="api-type-tabs">
          <a class="aws-tab active" href="apigateway-http-apis.html" aria-current="page" data-od-id="tab-http">HTTP APIs</a>
        </div>
        <div class="aws-card-body">
          <p class="aws-desc">HTTP APIs enable you to create RESTful APIs with lower latency and cost.</p>
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-delete-api" title="Select a row">Delete</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-api" title="To implement" disabled aria-disabled="true">Create</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search APIs", "find-apis")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="http-apis-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Name", { sort: true })}
                  ${th("API ID", { filter: true })}
                  ${th("Description", { filter: true })}
                  ${th("Created date", { sort: true })}
                  ${th("Endpoint", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="awsbox-http-demo">
                  <td class="check"><input type="checkbox" aria-label="Select awsbox-http-demo" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="api-demo">awsbox-http-demo</button></td>
                  <td><code class="aws-mono">a1b2c3d4</code></td>
                  <td>Lambda proxy demo</td>
                  <td>2026-10-19 11:22:08</td>
                  <td><code class="aws-mono">https://a1b2c3d4.execute-api.ap-southeast-2.amazonaws.com</code></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "cloudformation-stacks.html",
  title: "Stacks",
  page: "cloudformation-stacks",
  nav: "cloudformation-stacks",
  crumb: "Stacks",
  service: "cloudformation",
  serviceTitle: "CloudFormation",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Stacks <span class="aws-quiet">(2)</span></h1>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-delete-stack" title="Select a row">Delete</button>
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-update-stack" title="Select a row">Update ▾</button>
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-stack-actions" title="Select a row">Stack actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-stack" title="To implement" disabled aria-disabled="true">Create stack ▾</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search by stack name", "find-stacks")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="cfn-stacks-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Stack name", { sort: true })}
                  ${th("Status", { filter: true })}
                  ${th("Created time", { sort: true })}
                  ${th("Description", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="awsbox-demo">
                  <td class="check"><input type="checkbox" aria-label="Select awsbox-demo" /></td>
                  <td>${linkCell("cloudformation-stack-detail.html", "awsbox-demo", "stack-awsbox-demo")}</td>
                  <td>${status("success", "CREATE_COMPLETE")}</td>
                  <td>2026-10-12 08:41:15</td>
                  <td>Demo stack for local labs</td>
                </tr>
                <tr data-name="network-base">
                  <td class="check"><input type="checkbox" aria-label="Select network-base" /></td>
                  <td><a href="cloudformation-stack-detail.html" data-od-id="stack-network-base">network-base</a></td>
                  <td>${status("success", "UPDATE_COMPLETE")}</td>
                  <td>2026-09-03 14:02:55</td>
                  <td>VPC and subnet baseline</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "cloudformation-stack-detail.html",
  title: "awsbox-demo",
  page: "cloudformation-stack-detail",
  nav: "cloudformation-stack-detail",
  crumb: "awsbox-demo",
  service: "cloudformation",
  serviceTitle: "CloudFormation",
  main: `
      <div class="aws-detail-split" data-od-id="cfn-detail-layout" data-tabs>
        <aside class="aws-card" data-od-id="cfn-stack-rail">
          <div class="aws-card-body">
            <div class="aws-toolbar" style="margin-bottom:8px">
              <strong>Stacks (2)</strong>
              ${refreshBtn()}
            </div>
            <ul class="aws-rail-list">
              <li><a class="active" href="cloudformation-stack-detail.html"><span class="rail-name">awsbox-demo</span>${status("success", "CREATE_COMPLETE")}</a></li>
              <li><a href="cloudformation-stacks.html"><span class="rail-name">network-base</span>${status("success", "UPDATE_COMPLETE")}</a></li>
            </ul>
          </div>
        </aside>
        <div>
          <div class="aws-toolbar" data-od-id="detail-toolbar">
            <div style="flex:1;min-width:0">
              <h1 class="aws-h1" data-od-id="page-title" style="margin:0">awsbox-demo</h1>
              <div class="aws-subtitle-row">${status("success", "CREATE_COMPLETE")}<span>Created 2026-10-12 08:41:15</span></div>
            </div>
            <button type="button" class="btn btn-normal" data-od-id="btn-delete-stack" title="To implement" disabled aria-disabled="true">Delete</button>
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" title="To implement">Update ▾</button>
            <button type="button" class="btn btn-primary" disabled aria-disabled="true" title="To implement">Create stack ▾</button>
          </div>
          <section class="aws-card" data-od-id="content-card">
            <div class="aws-tabs" role="tablist" data-od-id="cfn-detail-tabs">
              <button type="button" class="aws-tab active" data-tab="info" aria-current="page">Stack info</button>
              <button type="button" class="aws-tab" data-tab="events">Events</button>
              <button type="button" class="aws-tab" data-tab="resources">Resources</button>
              <button type="button" class="aws-tab" data-tab="outputs">Outputs</button>
              <button type="button" class="aws-tab" data-tab="parameters">Parameters</button>
              <button type="button" class="aws-tab" data-tab="template">Template</button>
            </div>
            <div class="aws-card-body aws-tab-panels">
              <div data-tab-panel="info" data-od-id="panel-info">
                <h2 class="aws-section-title">Overview</h2>
                <dl class="aws-kv" data-od-id="stack-overview">
                  <div><dt>Stack ID</dt><dd><code class="aws-mono">arn:aws:cloudformation:ap-southeast-2:445772506418:stack/awsbox-demo/abc</code></dd></div>
                  <div><dt>Description</dt><dd>Demo stack for local labs</dd></div>
                  <div><dt>Created time</dt><dd>2026-10-12 08:41:15</dd></div>
                  <div><dt>Last updated time</dt><dd>—</dd></div>
                  <div><dt>Status</dt><dd>${status("success", "CREATE_COMPLETE")}</dd></div>
                  <div><dt>Disable rollback</dt><dd>false</dd></div>
                </dl>
                <h2 class="aws-section-title">Tags</h2>
                <p class="aws-desc">No tags</p>
              </div>
              <div data-tab-panel="events" hidden data-od-id="panel-events">
                <div class="aws-table-wrap">
                  <table class="aws-table" data-od-id="events-table">
                    <thead><tr>${th("Timestamp")}${th("Logical ID")}${th("Status")}${th("Status reason")}${th("Type")}</tr></thead>
                    <tbody>
                      <tr><td>2026-10-12 08:41:15</td><td>awsbox-demo</td><td>${status("success", "CREATE_COMPLETE")}</td><td>—</td><td>AWS::CloudFormation::Stack</td></tr>
                      <tr><td>2026-10-12 08:40:58</td><td>DemoBucket</td><td>${status("success", "CREATE_COMPLETE")}</td><td>—</td><td>AWS::S3::Bucket</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div data-tab-panel="resources" hidden data-od-id="panel-resources">
                <div class="aws-table-wrap">
                  <table class="aws-table" data-od-id="resources-table">
                    <thead><tr>${th("Logical ID")}${th("Physical ID")}${th("Type")}${th("Status")}</tr></thead>
                    <tbody>
                      <tr><td>DemoBucket</td><td><code class="aws-mono">awsbox-demo-bucket</code></td><td>AWS::S3::Bucket</td><td>${status("success", "CREATE_COMPLETE")}</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div data-tab-panel="outputs" hidden data-od-id="panel-outputs">
                <div class="aws-table-wrap">
                  <table class="aws-table" data-od-id="outputs-table">
                    <thead><tr>${th("Key")}${th("Value")}${th("Description")}</tr></thead>
                    <tbody>
                      <tr><td>BucketName</td><td><code class="aws-mono">awsbox-demo-bucket</code></td><td>Demo bucket name</td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div data-tab-panel="parameters" hidden data-od-id="panel-parameters">
                <div class="aws-table-wrap">
                  <table class="aws-table" data-od-id="parameters-table">
                    <thead><tr>${th("Key")}${th("Value")}</tr></thead>
                    <tbody>
                      <tr><td>Environment</td><td><code class="aws-mono">lab</code></td></tr>
                    </tbody>
                  </table>
                </div>
              </div>
              <div data-tab-panel="template" hidden data-od-id="panel-template">
                <pre class="aws-mono" style="white-space:pre-wrap;margin:0;color:var(--awsbox-body)">AWSTemplateFormatVersion: '2010-09-09'
Description: Demo stack for local labs
Resources:
  DemoBucket:
    Type: AWS::S3::Bucket</pre>
              </div>
            </div>
          </section>
        </div>
      </div>`,
});

pages.push({
  file: "transfer-servers.html",
  title: "Servers",
  page: "transfer-servers",
  nav: "transfer-servers",
  crumb: "Servers",
  service: "transfer",
  serviceTitle: "AWS Transfer Family",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Servers</h1>
      <p class="aws-desc">Transfer Family provides fully managed support for transferring files over SFTP, FTPS, and FTP.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-delete-server" title="Select a row">Delete</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-server" title="To implement" disabled aria-disabled="true">Create server</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search servers", "find-servers")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="transfer-servers-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Server ID", { sort: true })}
                  ${th("Protocol", { filter: true })}
                  ${th("Endpoint type", { filter: true })}
                  ${th("Identity provider", { filter: true })}
                  ${th("State", { filter: true })}
                  ${th("Users", { sort: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="s-abc12def34">
                  <td class="check"><input type="checkbox" aria-label="Select s-abc12def34" /></td>
                  <td>${linkCell("transfer-server-detail.html", "s-abc12def34", "xfer-s-abc12def34")}</td>
                  <td>SFTP</td>
                  <td>Public</td>
                  <td>Service managed</td>
                  <td>${status("success", "Online")}</td>
                  <td>2</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "transfer-server-detail.html",
  title: "s-abc12def34",
  page: "transfer-server-detail",
  nav: "transfer-server-detail",
  crumb: "s-abc12def34",
  service: "transfer",
  serviceTitle: "AWS Transfer Family",
  main: `
      <div class="aws-toolbar" data-od-id="detail-toolbar">
        <h1 class="aws-h1" data-od-id="page-title" style="margin:0;flex:1">s-abc12def34</h1>
        ${refreshBtn()}
      </div>
      <div class="aws-subtitle-row">${status("success", "Online")}<span>SFTP · Public endpoint</span></div>
      <section class="aws-card" data-od-id="overview-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Overview</h2>
          <dl class="aws-kv" data-od-id="server-overview">
            <div><dt>State</dt><dd>${status("success", "Online")}</dd></div>
            <div><dt>Protocols</dt><dd>SFTP</dd></div>
            <div><dt>Identity provider</dt><dd>Service managed</dd></div>
            <div><dt>Endpoint type</dt><dd>Public</dd></div>
            <div><dt>User count</dt><dd>2</dd></div>
            <div><dt>ARN</dt><dd><code class="aws-mono">arn:aws:transfer:ap-southeast-2:445772506418:server/s-abc12def34</code></dd></div>
          </dl>
        </div>
      </section>
      <section class="aws-card" style="margin-top:16px" data-od-id="users-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Users</h2>
          <div class="aws-table-wrap">
            <table class="aws-table" data-od-id="transfer-users-table">
              <thead><tr>${th("User name", { sort: true })}${th("Home directory")}${th("Role")}</tr></thead>
              <tbody>
                <tr><td>awsbox</td><td><code class="aws-mono">/awsbox-home</code></td><td><code class="aws-mono">arn:aws:iam::445772506418:role/TransferAccess</code></td></tr>
                <tr><td>partner</td><td><code class="aws-mono">/partner-drop</code></td><td><code class="aws-mono">arn:aws:iam::445772506418:role/TransferAccess</code></td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
      <section class="aws-card" style="margin-top:16px" data-od-id="dataplane-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Data plane</h2>
          <dl class="aws-kv" data-od-id="transfer-dataplane">
            <div><dt>Endpoint</dt><dd><code class="aws-mono">s-abc12def34.server.transfer.ap-southeast-2.amazonaws.com</code></dd></div>
            <div><dt>Port</dt><dd>22</dd></div>
            <div><dt>Protocol</dt><dd>SFTP</dd></div>
            <div><dt>Host key fingerprint</dt><dd><code class="aws-mono">SHA256:AbCdEf…</code></dd></div>
            <div><dt>Connect</dt><dd><code class="aws-mono">sftp awsbox@s-abc12def34.server.transfer.ap-southeast-2.amazonaws.com</code></dd></div>
          </dl>
        </div>
      </section>`,
});

pages.push({
  file: "rds-databases.html",
  title: "Databases",
  page: "rds-databases",
  nav: "rds-databases",
  crumb: "Databases",
  service: "rds",
  serviceTitle: "RDS",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Databases</h1>
      <p class="aws-desc">Amazon RDS makes it easier to set up, operate, and scale a relational database.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-actions" title="Select a row">Actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-db" title="To implement" disabled aria-disabled="true">Create database</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Filter databases", "find-dbs")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="rds-databases-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("DB identifier", { sort: true })}
                  ${th("Status", { filter: true })}
                  ${th("Role", { filter: true })}
                  ${th("Engine", { filter: true })}
                  ${th("Region & AZ", { filter: true })}
                  ${th("Size", { filter: true })}
                  ${th("VPC", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="awsbox-pg">
                  <td class="check"><input type="checkbox" aria-label="Select awsbox-pg" /></td>
                  <td>${linkCell("rds-instance-detail.html", "awsbox-pg", "db-awsbox-pg")}</td>
                  <td>${status("success", "Available")}</td>
                  <td>Instance</td>
                  <td>PostgreSQL 16.3</td>
                  <td>ap-southeast-2a</td>
                  <td>db.t4g.micro</td>
                  <td><code class="aws-mono">vpc-0a1b2c3d</code></td>
                </tr>
                <tr data-name="awsbox-mysql">
                  <td class="check"><input type="checkbox" aria-label="Select awsbox-mysql" /></td>
                  <td><a href="rds-instance-detail.html" data-od-id="db-awsbox-mysql">awsbox-mysql</a></td>
                  <td>${status("success", "Available")}</td>
                  <td>Instance</td>
                  <td>MySQL 8.0.39</td>
                  <td>ap-southeast-2b</td>
                  <td>db.t4g.micro</td>
                  <td><code class="aws-mono">vpc-0a1b2c3d</code></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "rds-instance-detail.html",
  title: "awsbox-pg",
  page: "rds-instance-detail",
  nav: "rds-instance-detail",
  crumb: "awsbox-pg",
  service: "rds",
  serviceTitle: "RDS",
  main: `
      <div class="aws-toolbar" data-od-id="detail-toolbar">
        <h1 class="aws-h1" data-od-id="page-title" style="margin:0;flex:1">awsbox-pg</h1>
        ${refreshBtn()}
        <button type="button" class="btn btn-normal" disabled aria-disabled="true" title="To implement">Actions ▾</button>
      </div>
      <div class="aws-subtitle-row">${status("success", "Available")}<span>PostgreSQL 16.3 · db.t4g.micro</span></div>
      <section class="aws-card" data-od-id="connectivity-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Connectivity & security</h2>
          <dl class="aws-kv" data-od-id="rds-connectivity">
            <div><dt>Endpoint</dt><dd><code class="aws-mono">awsbox-pg.abc123.ap-southeast-2.rds.amazonaws.com:5432</code></dd></div>
            <div><dt>Port</dt><dd>5432</dd></div>
            <div><dt>Master username</dt><dd>awsbox</dd></div>
            <div><dt>DB name</dt><dd>awsbox</dd></div>
            <div><dt>VPC</dt><dd><code class="aws-mono">vpc-0a1b2c3d</code></dd></div>
            <div><dt>Publicly accessible</dt><dd>No</dd></div>
            <div><dt>Connect</dt><dd><code class="aws-mono">psql -h 127.0.0.1 -p 5432 -U awsbox -d awsbox</code></dd></div>
          </dl>
        </div>
      </section>
      <section class="aws-card" style="margin-top:16px" data-od-id="config-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Configuration</h2>
          <dl class="aws-kv">
            <div><dt>DB instance class</dt><dd>db.t4g.micro</dd></div>
            <div><dt>Engine version</dt><dd>16.3</dd></div>
            <div><dt>Storage type</dt><dd>General Purpose SSD (gp3)</dd></div>
            <div><dt>Allocated storage</dt><dd>20 GiB</dd></div>
          </dl>
        </div>
      </section>`,
});

pages.push({
  file: "ecs-clusters.html",
  title: "Clusters",
  page: "ecs-clusters",
  nav: "ecs-clusters",
  crumb: "Clusters",
  service: "ecs",
  serviceTitle: "Elastic Container Service",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Clusters</h1>
      <p class="aws-desc">An Amazon ECS cluster is a logical grouping of tasks or services.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-delete-cluster" title="Select a row">Delete Cluster</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-cluster" title="To implement" disabled aria-disabled="true">Create Cluster</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Filter clusters", "find-clusters")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="ecs-clusters-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Cluster name", { sort: true })}
                  ${th("Status", { filter: true })}
                  ${th("Registered container instances", { sort: true })}
                  ${th("Services", { sort: true })}
                  ${th("Tasks running", { sort: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="awsbox-lab">
                  <td class="check"><input type="checkbox" aria-label="Select awsbox-lab" /></td>
                  <td>${linkCell("ecs-cluster-detail.html", "awsbox-lab", "cluster-awsbox-lab")}</td>
                  <td>${status("success", "ACTIVE")}</td>
                  <td>0</td>
                  <td>1</td>
                  <td>1</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "ecs-cluster-detail.html",
  title: "awsbox-lab",
  page: "ecs-cluster-detail",
  nav: "ecs-cluster-detail",
  crumb: "awsbox-lab",
  service: "ecs",
  serviceTitle: "Elastic Container Service",
  main: `
      <div class="aws-toolbar" data-od-id="detail-toolbar">
        <h1 class="aws-h1" data-od-id="page-title" style="margin:0;flex:1">awsbox-lab</h1>
        ${refreshBtn()}
      </div>
      <div class="aws-subtitle-row">${status("success", "ACTIVE")}</div>
      <section class="aws-card" data-od-id="overview-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Overview</h2>
          <dl class="aws-kv">
            <div><dt>Status</dt><dd>${status("success", "ACTIVE")}</dd></div>
            <div><dt>ARN</dt><dd><code class="aws-mono">arn:aws:ecs:ap-southeast-2:445772506418:cluster/awsbox-lab</code></dd></div>
            <div><dt>Active services</dt><dd>1</dd></div>
            <div><dt>Running tasks</dt><dd>1</dd></div>
          </dl>
        </div>
      </section>
      <section class="aws-card" style="margin-top:16px" data-od-id="services-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Services</h2>
          <div class="aws-table-wrap">
            <table class="aws-table" data-od-id="ecs-services-table">
              <thead><tr>${th("Service name")}${th("Status")}${th("Desired tasks")}${th("Running tasks")}</tr></thead>
              <tbody>
                <tr><td>web</td><td>${status("success", "ACTIVE")}</td><td>1</td><td>1</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
      <section class="aws-card" style="margin-top:16px" data-od-id="tasks-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title">Tasks</h2>
          <div class="aws-table-wrap">
            <table class="aws-table" data-od-id="ecs-tasks-table">
              <thead><tr>${th("Task")}${th("Last status")}${th("Desired status")}${th("Launch type")}</tr></thead>
              <tbody>
                <tr><td><code class="aws-mono">1a2b3c4d5e6f</code></td><td>${status("success", "RUNNING")}</td><td>RUNNING</td><td>FARGATE</td></tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "ec2-instances.html",
  title: "Instances",
  page: "ec2-instances",
  nav: "ec2-instances",
  crumb: "Instances",
  service: "ec2",
  serviceTitle: "EC2",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Instances</h1>
      <p class="aws-desc">Virtual servers in the cloud. Launch, connect, and manage instances here.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-instance-state" title="Select a row">Instance state ▾</button>
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-actions" title="Select a row">Actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-launch" title="To implement" disabled aria-disabled="true">Launch instance</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search by name, ID, or IP", "find-instances")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="ec2-instances-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Name", { sort: true })}
                  ${th("Instance ID", { sort: true })}
                  ${th("Instance state", { filter: true })}
                  ${th("Instance type", { filter: true })}
                  ${th("Availability Zone", { filter: true })}
                  ${th("Public IPv4 DNS", { filter: true })}
                  ${th("Private IPv4", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="lab-web">
                  <td class="check"><input type="checkbox" aria-label="Select lab-web" /></td>
                  <td>lab-web</td>
                  <td><code class="aws-mono">i-0abc123def456</code></td>
                  <td>${status("success", "Running")}</td>
                  <td>t3.micro</td>
                  <td>ap-southeast-2a</td>
                  <td><code class="aws-mono">ec2-13-…ap-southeast-2.compute.amazonaws.com</code></td>
                  <td>10.0.1.24</td>
                </tr>
                <tr data-name="lab-worker">
                  <td class="check"><input type="checkbox" aria-label="Select lab-worker" /></td>
                  <td>lab-worker</td>
                  <td><code class="aws-mono">i-0fed654cba321</code></td>
                  <td>${status("success", "Running")}</td>
                  <td>t3.small</td>
                  <td>ap-southeast-2b</td>
                  <td>—</td>
                  <td>10.0.2.18</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "ec2-vpcs.html",
  title: "Your VPCs",
  page: "ec2-vpcs",
  nav: "ec2-vpcs",
  crumb: "Your VPCs",
  service: "ec2",
  serviceTitle: "EC2",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Your VPCs</h1>
      <p class="aws-desc">A virtual private cloud (VPC) is a virtual network dedicated to your account.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-actions" title="Select a row">Actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-vpc" title="To implement" disabled aria-disabled="true">Create VPC</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search VPCs", "find-vpcs")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="ec2-vpcs-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Name", { sort: true })}
                  ${th("VPC ID", { sort: true })}
                  ${th("State", { filter: true })}
                  ${th("IPv4 CIDR", { filter: true })}
                  ${th("IPv6 CIDR", { filter: true })}
                  ${th("DHCP option set", { filter: true })}
                  ${th("Default VPC", { filter: true })}
                  ${th("Owner ID", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="lab-vpc">
                  <td class="check"><input type="checkbox" aria-label="Select lab-vpc" /></td>
                  <td>lab-vpc</td>
                  <td>${linkCell("ec2-vpc-detail.html", "vpc-0a1b2c3d", "vpc-0a1b2c3d")}</td>
                  <td>${status("success", "Available")}</td>
                  <td>10.0.0.0/16</td>
                  <td>—</td>
                  <td><code class="aws-mono">dopt-0123abcd</code></td>
                  <td>No</td>
                  <td>445772506418</td>
                </tr>
                <tr data-name="default">
                  <td class="check"><input type="checkbox" aria-label="Select default VPC" /></td>
                  <td>—</td>
                  <td><a href="ec2-vpc-detail.html" data-od-id="vpc-default">vpc-0deadbeef</a></td>
                  <td>${status("success", "Available")}</td>
                  <td>172.31.0.0/16</td>
                  <td>—</td>
                  <td><code class="aws-mono">dopt-0default</code></td>
                  <td>Yes</td>
                  <td>445772506418</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "ec2-vpc-detail.html",
  title: "vpc-0a1b2c3d",
  page: "ec2-vpc-detail",
  nav: "ec2-vpc-detail",
  crumb: "vpc-0a1b2c3d",
  service: "ec2",
  serviceTitle: "EC2",
  main: `
      <div class="aws-toolbar" data-od-id="detail-toolbar">
        <h1 class="aws-h1" data-od-id="page-title" style="margin:0;flex:1">vpc-0a1b2c3d</h1>
        ${refreshBtn()}
        <button type="button" class="btn btn-normal" disabled aria-disabled="true" title="To implement">Actions ▾</button>
      </div>
      <div class="aws-subtitle-row">${status("success", "Available")}<span>lab-vpc</span></div>
      <section class="aws-card" data-od-id="overview-card" data-tabs>
        <div class="aws-tabs" role="tablist" data-od-id="vpc-detail-tabs">
          <button type="button" class="aws-tab active" data-tab="details" aria-current="page">Details</button>
          <button type="button" class="aws-tab" data-tab="cidrs">CIDR blocks</button>
          <button type="button" class="aws-tab" data-tab="subnets">Subnets</button>
          <button type="button" class="aws-tab" data-tab="tags">Tags</button>
        </div>
        <div class="aws-card-body aws-tab-panels">
          <div data-tab-panel="details" data-od-id="panel-details">
            <h2 class="aws-section-title">Details</h2>
            <dl class="aws-kv" data-od-id="vpc-overview">
              <div><dt>VPC ID</dt><dd><code class="aws-mono">vpc-0a1b2c3d</code></dd></div>
              <div><dt>State</dt><dd>${status("success", "Available")}</dd></div>
              <div><dt>IPv4 CIDR</dt><dd>10.0.0.0/16</dd></div>
              <div><dt>IPv6 CIDR</dt><dd>—</dd></div>
              <div><dt>DHCP option set</dt><dd><code class="aws-mono">dopt-0123abcd</code></dd></div>
              <div><dt>Tenancy</dt><dd>Default</dd></div>
              <div><dt>Default VPC</dt><dd>No</dd></div>
              <div><dt>Owner ID</dt><dd>445772506418</dd></div>
            </dl>
          </div>
          <div data-tab-panel="cidrs" hidden data-od-id="panel-cidrs">
            <div class="aws-table-wrap">
              <table class="aws-table" data-od-id="vpc-cidrs-table">
                <thead><tr>${th("CIDR")}${th("State")}${th("Association ID")}</tr></thead>
                <tbody>
                  <tr><td>10.0.0.0/16</td><td>${status("success", "Associated")}</td><td><code class="aws-mono">vpc-cidr-assoc-0abc</code></td></tr>
                </tbody>
              </table>
            </div>
          </div>
          <div data-tab-panel="subnets" hidden data-od-id="panel-subnets">
            <div class="aws-table-wrap">
              <table class="aws-table" data-od-id="vpc-subnets-table">
                <thead><tr>${th("Name")}${th("Subnet ID")}${th("CIDR")}${th("AZ")}${th("State")}</tr></thead>
                <tbody>
                  <tr><td>lab-public-a</td><td><code class="aws-mono">subnet-0aaa1111</code></td><td>10.0.1.0/24</td><td>ap-southeast-2a</td><td>${status("success", "Available")}</td></tr>
                  <tr><td>lab-private-b</td><td><code class="aws-mono">subnet-0bbb2222</code></td><td>10.0.2.0/24</td><td>ap-southeast-2b</td><td>${status("success", "Available")}</td></tr>
                </tbody>
              </table>
            </div>
          </div>
          <div data-tab-panel="tags" hidden data-od-id="panel-tags">
            <p class="aws-desc">No tags</p>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "ec2-load-balancers.html",
  title: "Load balancers",
  page: "ec2-load-balancers",
  nav: "ec2-load-balancers",
  crumb: "Load balancers",
  service: "ec2",
  serviceTitle: "EC2",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Load balancers</h1>
      <p class="aws-desc">Distribute incoming traffic across multiple targets in one or more Availability Zones.</p>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-actions" title="Select a row">Actions ▾</button>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-lb" title="To implement" disabled aria-disabled="true">Create load balancer</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Search load balancers", "find-lbs")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="ec2-lbs-table">
              <thead>
                <tr>
                  ${checkTh()}
                  ${th("Name", { sort: true })}
                  ${th("DNS name", { filter: true })}
                  ${th("State", { filter: true })}
                  ${th("VPC ID", { filter: true })}
                  ${th("Availability Zones", { filter: true })}
                  ${th("Type", { filter: true })}
                  ${th("Date created", { sort: true })}
                </tr>
              </thead>
              <tbody>
                <tr data-name="lab-alb">
                  <td class="check"><input type="checkbox" aria-label="Select lab-alb" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement" data-od-id="lb-lab-alb">lab-alb</button></td>
                  <td><code class="aws-mono">lab-alb-123456789.ap-southeast-2.elb.amazonaws.com</code></td>
                  <td>${status("success", "Active")}</td>
                  <td><code class="aws-mono">vpc-0a1b2c3d</code></td>
                  <td>ap-southeast-2a, ap-southeast-2b</td>
                  <td>application</td>
                  <td>2026-10-08 10:15:33</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

const emptyPages = [
  {
    file: "iam-users-empty.html",
    title: "Users",
    page: "iam-users-empty",
    nav: "iam-users",
    crumb: "Users",
    service: "iam",
    serviceTitle: "IAM",
    main: emptyListMain({
      title: "Users",
      desc: "An IAM user is an identity with long-term credentials used to interact with awsbox.",
      createLabel: "Create user",
      createId: "btn-create-user",
      emptyHeading: "No users",
      emptyCopy: "You do not have any IAM users in this account yet.",
      filledHref: "iam-users.html",
    }),
  },
  {
    file: "lambda-functions-empty.html",
    title: "Functions",
    page: "lambda-functions-empty",
    nav: "lambda-functions",
    crumb: "Functions",
    service: "lambda",
    serviceTitle: "Lambda",
    main: emptyListMain({
      title: "Functions",
      desc: "Lambda lets you run code without provisioning or managing servers.",
      createLabel: "Create function",
      createId: "btn-create-function",
      emptyHeading: "No functions",
      emptyCopy: "You do not have any Lambda functions in this region.",
      filledHref: "lambda-functions.html",
    }),
  },
  {
    file: "logs-log-groups-empty.html",
    title: "Log groups",
    page: "logs-log-groups-empty",
    nav: "logs-log-groups",
    crumb: "Log groups",
    service: "logs",
    serviceTitle: "CloudWatch",
    main: emptyListMain({
      title: "Log groups",
      desc: "A log group is a group of log streams that share the same retention, monitoring, and access control settings.",
      createLabel: "Create log group",
      createId: "btn-create-log-group",
      emptyHeading: "No log groups",
      emptyCopy: "No log groups match this region yet.",
      filledHref: "logs-log-groups.html",
    }),
  },
  {
    file: "apigateway-http-apis-empty.html",
    title: "HTTP APIs",
    page: "apigateway-http-apis-empty",
    nav: "apigateway-http-apis",
    crumb: "HTTP APIs",
    service: "apigateway",
    serviceTitle: "API Gateway",
    main: `
      <h1 class="aws-h1" data-od-id="page-title">APIs</h1>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-tabs" role="tablist" data-od-id="api-type-tabs">
          <a class="aws-tab active" href="apigateway-http-apis-empty.html" aria-current="page" data-od-id="tab-http">HTTP APIs</a>
        </div>
        <div class="aws-card-body">
          <p class="aws-desc">HTTP APIs enable you to create RESTful APIs with lower latency and cost.</p>
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-create-api" disabled aria-disabled="true" title="To implement">Create</button>
          </div>
          <div class="aws-empty-panel" data-od-id="empty-state">
            <strong>No HTTP APIs</strong>
            <p>You do not have any HTTP APIs in this region.</p>
            <p class="aws-desc" style="margin-top:12px"><a href="apigateway-http-apis.html">View sample rows</a></p>
          </div>
        </div>
      </section>`,
  },
];

for (const p of [...pages, ...emptyPages]) {
  fs.writeFileSync(path.join(screensDir, p.file), pageShell(p));
  console.log("wrote", p.file);
}

const index = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>awsbox console</title>
  <link rel="stylesheet" href="assets/fonts.css" />
  <link rel="stylesheet" href="assets/console.css" />
</head>
<body>
  <main class="launcher" data-od-id="launcher">
    <h1 data-od-id="launcher-title">awsbox console</h1>
    <p>Issue #319 · grey-rose service screens · shared chrome. S3 screens from #304 sync — claim #319 only.</p>

    <h2 class="aws-section-title" style="margin:24px 0 12px">Services (#319)</h2>
    <div class="launcher-grid">
      <a href="screens/iam-users.html">IAM Users<span class="meta">Users list · sample rows</span></a>
      <a href="screens/iam-users-empty.html">IAM Users (empty)<span class="meta">Empty panel</span></a>
      <a href="screens/lambda-functions.html">Lambda Functions<span class="meta">Functions list</span></a>
      <a href="screens/lambda-functions-empty.html">Lambda Functions (empty)<span class="meta">Empty panel</span></a>
      <a href="screens/logs-log-groups.html">CloudWatch Log groups<span class="meta">Log groups list</span></a>
      <a href="screens/logs-log-groups-empty.html">CloudWatch Log groups (empty)<span class="meta">Empty panel</span></a>
      <a href="screens/apigateway-http-apis.html">API Gateway HTTP APIs<span class="meta">HTTP APIs tab</span></a>
      <a href="screens/apigateway-http-apis-empty.html">API Gateway HTTP APIs (empty)<span class="meta">Empty panel</span></a>
      <a href="screens/cloudformation-stacks.html">CloudFormation stacks<span class="meta">Stacks list</span></a>
      <a href="screens/cloudformation-stack-detail.html">CloudFormation stack detail<span class="meta">Info / Events / Resources / …</span></a>
      <a href="screens/transfer-servers.html">Transfer Family servers<span class="meta">Servers list</span></a>
      <a href="screens/transfer-server-detail.html">Transfer server detail<span class="meta">Users + data plane</span></a>
      <a href="screens/rds-databases.html">RDS Databases<span class="meta">Databases list</span></a>
      <a href="screens/rds-instance-detail.html">RDS instance detail<span class="meta">Connectivity + config</span></a>
      <a href="screens/ecs-clusters.html">ECS Clusters<span class="meta">Clusters list</span></a>
      <a href="screens/ecs-cluster-detail.html">ECS cluster detail<span class="meta">Services + tasks</span></a>
      <a href="screens/ec2-instances.html">EC2 Instances<span class="meta">Instances list</span></a>
      <a href="screens/ec2-vpcs.html">EC2 VPCs<span class="meta">Your VPCs</span></a>
      <a href="screens/ec2-vpc-detail.html">EC2 VPC detail<span class="meta">Details / CIDRs / Subnets</span></a>
      <a href="screens/ec2-load-balancers.html">EC2 Load balancers<span class="meta">ALB list</span></a>
    </div>

    <h2 class="aws-section-title" style="margin:32px 0 12px">S3 (#304)</h2>
    <div class="launcher-grid">
      <a href="screens/directory-buckets.html">Directory buckets<span class="meta">GP + Directory tabs · Create disabled</span></a>
      <a href="screens/general-purpose-buckets.html">General purpose buckets<span class="meta">Side widgets · Create enabled</span></a>
      <a href="screens/bucket-objects.html">Bucket objects<span class="meta">Objects tab + Actions</span></a>
      <a href="screens/table-buckets.html">Table buckets<span class="meta">Integration + ARN column</span></a>
      <a href="screens/vector-buckets.html">Vector buckets<span class="meta">Create disabled</span></a>
      <a href="screens/file-systems.html">File systems<span class="meta">S3 Files columns</span></a>
      <a href="screens/access-points.html">Access Points<span class="meta">4 tabs · 7 columns</span></a>
      <a href="screens/access-points-fsx.html">Access Points for FSx<span class="meta">FSx for ONTAP filter</span></a>
      <a href="screens/access-grants.html">Access Grants<span class="meta">Getting started + instance</span></a>
      <a href="screens/iam-access-analyzer.html">IAM Access Analyzer<span class="meta">Findings empty state</span></a>
      <a href="screens/storage-lens.html">Storage Lens<span class="meta">Dashboards / groups tabs</span></a>
      <a href="screens/batch-operations.html">Batch Operations<span class="meta">Jobs empty copy</span></a>
      <a href="screens/account-organization-settings.html">Account and organization settings<span class="meta">BPA + Org Storage Lens</span></a>
      <a href="screens/marketplace-for-s3.html">AWS Marketplace for S3<span class="meta">Expanded sidebar categories</span></a>
    </div>
  </main>
</body>
</html>
`;
fs.writeFileSync(path.join(root, "index.html"), index);
console.log("wrote index.html");
console.log("done", pages.length, "service screens +", emptyPages.length, "empty");
