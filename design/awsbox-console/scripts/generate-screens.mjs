import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const screensDir = path.join(root, "screens");
fs.mkdirSync(screensDir, { recursive: true });

function pageShell({ title, page, nav, crumb, main }) {
  return `<!doctype html>
<html lang="en" data-asset-base="../assets">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${title} — S3</title>
  <link rel="stylesheet" href="../assets/fonts.css" />
  <link rel="stylesheet" href="../assets/console.css" />
</head>
<body data-page="${page}" data-nav="${nav}" data-title="${title}" data-crumb="${crumb}">
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
    ? ` <button type="button" class="filter" aria-label="Filter ${label}">▾</button>`
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

function disabledBtn(label, odId) {
  return `<button type="button" class="btn btn-normal" disabled aria-disabled="true"${
    odId ? ` data-od-id="${odId}"` : ""
  } title="To implement">${label}</button>`;
}

function selectRowBtn(label, odId) {
  return `<button type="button" class="btn btn-normal" disabled aria-disabled="true"${
    odId ? ` data-od-id="${odId}"` : ""
  } title="Select a row">${label}</button>`;
}

function emptyPanelPage({ heading, createLabel, emptyTitle, emptyBody, odPrefix }) {
  return `
      <h1 class="aws-h1" data-od-id="page-title">${heading}</h1>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-card-body">
          <div class="aws-toolbar" data-od-id="action-toolbar">
            <h2 class="aws-section-title" style="margin:0;flex:1" data-od-id="section-title">${heading} (0)</h2>
            ${refreshBtn()}
            <button type="button" class="btn btn-primary" data-od-id="btn-create" disabled aria-disabled="true" title="To implement">${createLabel}</button>
          </div>
          <div class="aws-empty-panel" data-od-id="${odPrefix}-empty">
            <strong>${emptyTitle}</strong>
            <p>${emptyBody}</p>
          </div>
        </div>
      </section>`;
}

const pages = [];

pages.push({
  file: "directory-buckets.html",
  title: "Directory buckets",
  page: "directory-buckets",
  nav: "directory-buckets",
  crumb: "Buckets",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Buckets</h1>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-tabs" role="tablist" data-od-id="bucket-type-tabs">
          <a class="aws-tab" href="general-purpose-buckets.html" data-od-id="tab-general-purpose">General purpose buckets <span class="aws-badge">All AWS Regions</span></a>
          <a class="aws-tab active" href="directory-buckets.html" aria-current="page" data-od-id="tab-directory">Directory buckets</a>
        </div>
        <div class="aws-card-body">
          <h2 class="aws-section-title" data-od-id="section-title">Directory buckets (0) <button type="button" class="info" disabled aria-disabled="true" title="To implement">Info</button></h2>
          <p class="aws-desc">Directory buckets are optimized for use cases that require consistent single-digit millisecond latency.</p>
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            ${selectRowBtn("Copy ARN", "btn-copy-arn")}
            ${selectRowBtn("Empty", "btn-empty")}
            ${selectRowBtn("Delete", "btn-delete")}
            ${disabledBtn("Import", "btn-import")}
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" disabled aria-disabled="true" title="To implement" data-od-id="btn-create-bucket">Create bucket</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Find buckets by name", "find-buckets")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="directory-buckets-table">
              <thead>
                <tr>
                  ${th("Name", { sort: true })}
                  ${th("Bucket location type", { filter: true })}
                  ${th("Bucket location name", { filter: true })}
                  ${th("Creation date", { filter: true })}
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td class="empty-cell" colspan="4">
                    <strong>No buckets</strong>
                    You don't have any directory buckets in the Asia Pacific (Sydney) ap-southeast-2 Region.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "general-purpose-buckets.html",
  title: "General purpose buckets",
  page: "general-purpose-buckets",
  nav: "general-purpose-buckets",
  crumb: "Buckets",
  main: `
      <div class="aws-main-split" data-od-id="gp-layout">
        <div class="aws-main-primary">
          <h1 class="aws-h1" data-od-id="page-title">Buckets</h1>
          <section class="aws-card" data-od-id="content-card">
            <div class="aws-tabs" role="tablist" data-od-id="bucket-type-tabs">
              <a class="aws-tab active" href="general-purpose-buckets.html" aria-current="page" data-od-id="tab-general-purpose">General purpose buckets <span class="aws-badge">All AWS Regions</span></a>
              <a class="aws-tab" href="directory-buckets.html" data-od-id="tab-directory">Directory buckets</a>
            </div>
            <div class="aws-card-body">
              <h2 class="aws-section-title" data-od-id="section-title">General purpose buckets (0) <button type="button" class="info" disabled aria-disabled="true" title="To implement">Info</button></h2>
              <p class="aws-desc">Buckets are containers for data stored in S3.</p>
              <div class="aws-toolbar" data-od-id="action-toolbar">
                ${refreshBtn()}
                ${selectRowBtn("Copy ARN", "btn-copy-arn")}
                ${selectRowBtn("Empty", "btn-empty")}
                ${selectRowBtn("Delete", "btn-delete")}
                ${disabledBtn("Import", "btn-import")}
                <div class="spacer"></div>
                <button type="button" class="btn btn-primary" data-od-id="btn-create-bucket" title="To implement" disabled aria-disabled="true">Create bucket</button>
              </div>
              <div class="aws-table-tools">
                ${findField("Find buckets by name", "find-buckets")}
                ${pager()}
              </div>
              <div class="aws-table-wrap">
                <table class="aws-table" id="data-table" data-od-id="gp-buckets-table">
                  <thead>
                    <tr>
                      ${th("Name", { sort: true })}
                      ${th("AWS Region", { filter: true })}
                      ${th("Creation date", { filter: true })}
                    </tr>
                  </thead>
                  <tbody>
                    <tr>
                      <td class="empty-cell" colspan="3">
                        <strong>No buckets</strong>
                        You don't have any general purpose buckets.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </section>
        </div>
        <aside class="aws-side-widgets" data-od-id="gp-side-widgets">
          <section class="aws-widget" data-od-id="widget-account-snapshot">
            <div class="aws-widget-head">
              <h3>Account snapshot</h3>
              <span class="aws-chip">Updated daily</span>
            </div>
            <p>Storage Lens provides visibility into storage usage and activity trends.</p>
            <a class="btn btn-normal" href="storage-lens.html" data-od-id="btn-view-dashboard">View dashboard</a>
          </section>
          <section class="aws-widget" data-od-id="widget-external-access">
            <div class="aws-widget-head">
              <h3>External access summary</h3>
              <span class="aws-chip">Updated daily</span>
            </div>
            <p>External access findings help you identify bucket permissions that allow public access or access from other AWS accounts.</p>
          </section>
        </aside>
      </div>`,
});

pages.push({
  file: "bucket-objects.html",
  title: "Objects",
  page: "bucket-objects",
  nav: "directory-buckets",
  crumb: "test--apse2-az1--x-s3",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">test--apse2-az1--x-s3 <button type="button" class="info" disabled aria-disabled="true" title="To implement" style="font-size:14px;font-weight:400">Info</button></h1>
      <section class="aws-card" data-od-id="content-card">
        <div class="aws-tabs" role="tablist" data-od-id="bucket-tabs">
          <a class="aws-tab active" href="bucket-objects.html" aria-current="page">Objects</a>
          <button type="button" class="aws-tab" disabled aria-disabled="true" title="To implement">Properties</button>
          <button type="button" class="aws-tab" disabled aria-disabled="true" title="To implement" data-od-id="tab-permissions">Permissions</button>
          <button type="button" class="aws-tab" disabled aria-disabled="true" title="To implement" data-od-id="tab-metrics">Metrics</button>
          <button type="button" class="aws-tab" disabled aria-disabled="true" title="To implement" data-od-id="tab-management">Management</button>
          <button type="button" class="aws-tab" disabled aria-disabled="true" title="To implement" data-od-id="tab-access-points">Access Points</button>
        </div>
        <div class="aws-card-body">
          <h2 class="aws-section-title" data-od-id="section-title">Objects (1/1) <button type="button" class="info" disabled aria-disabled="true" title="To implement">Info</button></h2>
          <p class="aws-desc">Objects are the fundamental entities stored in Amazon S3. For others to access your objects, you’ll need to explicitly grant them permissions. <a href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingObjects.html" target="_blank" rel="noopener" data-od-id="learn-more">Learn more ↗</a></p>
          <div class="aws-toolbar" data-od-id="action-toolbar">
            ${refreshBtn()}
            <button type="button" class="btn btn-normal" data-od-id="btn-copy-uri" title="To implement" disabled aria-disabled="true">Copy S3 URI</button>
            <button type="button" class="btn btn-normal" data-od-id="btn-copy-url" title="To implement" disabled aria-disabled="true">Copy URL</button>
            <button type="button" class="btn btn-normal" title="To implement" disabled aria-disabled="true">Download</button>
            <button type="button" class="btn btn-normal" title="To implement" disabled aria-disabled="true">Open ↗</button>
            <button type="button" class="btn btn-normal" title="To implement" disabled aria-disabled="true">Delete</button>
            <div class="aws-pop">
              <button type="button" class="btn btn-normal" id="btn-actions" aria-expanded="false" aria-controls="menu-actions" data-od-id="btn-actions">Actions ▾</button>
              <div class="aws-menu left" id="menu-actions" data-menu>
                <button type="button" title="To implement" disabled aria-disabled="true">Edit metadata</button>
                <button type="button" title="To implement" disabled aria-disabled="true">Edit storage class</button>
                <button type="button" title="To implement" disabled aria-disabled="true">Share with a presigned URL</button>
                <div class="sep"></div>
                <button type="button" title="To implement" disabled aria-disabled="true">Rename object</button>
              </div>
            </div>
            <div class="spacer"></div>
            <button type="button" class="btn btn-primary" data-od-id="btn-upload" title="To implement" disabled aria-disabled="true">↑ Upload</button>
          </div>
          <div class="aws-table-tools">
            ${findField("Find objects by prefix")}
            ${pager()}
          </div>
          <div class="aws-table-wrap">
            <table class="aws-table" id="data-table" data-od-id="objects-table">
              <thead>
                <tr>
                  <th class="check" scope="col"><input type="checkbox" checked aria-label="Select all" /></th>
                  ${th("Name", { sort: true })}
                  <th scope="col">Type</th>
                  <th scope="col">Last modified</th>
                  <th scope="col">Size</th>
                  <th scope="col">Storage class</th>
                </tr>
              </thead>
              <tbody>
                <tr class="selected" data-name="aGX9P7JB_700w_0.jpg">
                  <td class="check"><input type="checkbox" checked aria-label="Select object" /></td>
                  <td><button type="button" class="aws-dead-link" disabled aria-disabled="true" title="To implement">aGX9P7JB_700w_0.jpg</button></td>
                  <td>jpg</td>
                  <td>October 18, 2026, 14:03:42 (UTC+10:00)</td>
                  <td>163.7 KB</td>
                  <td>S3 Express One Zone</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
      <script>
        document.addEventListener("DOMContentLoaded", function () {
          var btn = document.getElementById("btn-actions");
          var menu = document.getElementById("menu-actions");
          if (btn && menu) {
            btn.addEventListener("click", function (e) {
              e.stopPropagation();
              var open = !menu.classList.contains("open");
              menu.classList.toggle("open", open);
              btn.setAttribute("aria-expanded", open ? "true" : "false");
            });
          }
        });
      </script>`,
});

pages.push({
  file: "table-buckets.html",
  title: "Table buckets",
  page: "table-buckets",
  nav: "table-buckets",
  crumb: "Table buckets",
  main: emptyPanelPage({
    heading: "Table buckets",
    createLabel: "Create table bucket",
    emptyTitle: "No table buckets",
    emptyBody: "S3 Tables are not available on this local stack. Use General purpose buckets.",
    odPrefix: "table-buckets",
  }),
});

pages.push({
  file: "vector-buckets.html",
  title: "Vector buckets",
  page: "vector-buckets",
  nav: "vector-buckets",
  crumb: "Vector buckets",
  main: emptyPanelPage({
    heading: "Vector buckets",
    createLabel: "Create vector bucket",
    emptyTitle: "No vector buckets",
    emptyBody: "S3 Vectors are not available on this local stack. Use General purpose buckets.",
    odPrefix: "vector-buckets",
  }),
});

pages.push({
  file: "file-systems.html",
  title: "File systems",
  page: "file-systems",
  nav: "file-systems",
  crumb: "File systems",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">File systems <button type="button" class="info" disabled aria-disabled="true" title="To implement">Info</button></h1>
      <p class="aws-desc" data-od-id="page-desc">Amazon S3 Files is a high-performance shared file system to access S3 data from any AWS compute service.</p>
      <div class="aws-toolbar" data-od-id="action-toolbar">
        ${refreshBtn()}
        ${disabledBtn("View details", "btn-view")}
        ${disabledBtn("Delete", "btn-delete")}
        <div class="spacer"></div>
        <button type="button" class="btn btn-primary" data-od-id="btn-create" title="To implement" disabled aria-disabled="true">Create file system</button>
        ${pager()}
      </div>
      <details class="aws-getting-started" open data-od-id="getting-started">
        <summary>Getting started with S3 Files</summary>
        <p class="aws-desc" style="margin:12px 0 0">Create a file system, attach it to a general purpose bucket, and mount it from your compute environment.</p>
      </details>
      <div class="aws-table-wrap" style="margin-top:16px">
        <table class="aws-table" id="data-table" data-od-id="file-systems-table">
          <thead>
            <tr>
              ${checkTh()}
              ${th("File system ID", { filter: true })}
              ${th("Name", { filter: true })}
              ${th("General purpose bucket", { filter: true })}
              ${th("Status", { filter: true })}
              ${th("Creation date", { filter: true })}
            </tr>
          </thead>
          <tbody>
            <tr>
              <td class="empty-cell" colspan="6">
                <strong>No file systems</strong>
                You don't have any file systems in this Region.
              </td>
            </tr>
          </tbody>
        </table>
      </div>`,
});

pages.push({
  file: "access-points.html",
  title: "Access Points",
  page: "access-points",
  nav: "access-points",
  crumb: "Access Points",
  main: emptyPanelPage({
    heading: "Access Points",
    createLabel: "Create access point",
    emptyTitle: "No access points",
    emptyBody: "S3 Access Points are not available on this local stack. General purpose buckets work without them.",
    odPrefix: "access-points",
  }),
});

pages.push({
  file: "access-points-fsx.html",
  title: "Access Points for FSx",
  page: "access-points-fsx",
  nav: "access-points-fsx",
  crumb: "Access Points for FSx",
  main: emptyPanelPage({
    heading: "Access Points for FSx",
    createLabel: "Create access point",
    emptyTitle: "No Access Points for FSx",
    emptyBody: "Access Points for FSx are not available on this local stack.",
    odPrefix: "access-points-fsx",
  }),
});

pages.push({
  file: "access-grants.html",
  title: "Access Grants",
  page: "access-grants",
  nav: "access-grants",
  crumb: "Access Grants",
  main: emptyPanelPage({
    heading: "Access Grants",
    createLabel: "Create grant",
    emptyTitle: "No Access Grants",
    emptyBody: "S3 Access Grants are not available on this local stack.",
    odPrefix: "access-grants",
  }),
});

pages.push({
  file: "iam-access-analyzer.html",
  title: "IAM Access Analyzer",
  page: "iam-access-analyzer",
  nav: "iam-access-analyzer",
  crumb: "IAM Access Analyzer for S3",
  main: `
      <div class="aws-toolbar" style="align-items:flex-start">
        <div style="flex:1;min-width:0">
          <h1 class="aws-h1" data-od-id="page-title">IAM Access Analyzer for S3 <button type="button" class="info" disabled aria-disabled="true" title="To implement">Info</button></h1>
          <p class="aws-desc" data-od-id="page-desc">When a bucket policy, Access Point policy, or ACL is added or modified, IAM Access Analyzer generates and updates findings based on the change within 30 minutes. Findings related to account-level Block public access settings or Multi-Region Access Point configurations may not be generated or updated for up to 6 hours after you change the settings. Findings in the following lists are aggregated by bucket. <a href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-analyzer.html" target="_blank" rel="noopener">Learn more ↗</a></p>
        </div>
        <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-download" title="To implement">Download report</button>
      </div>
      <section class="aws-card" data-od-id="findings-card">
        <div class="aws-card-body">
          <h2 class="aws-section-title" data-od-id="findings-title">Findings</h2>
          <div class="aws-empty-panel">
            <strong>No findings to display</strong>
            <p>When Access Analyzer finds buckets that allow public or cross-account access, they appear here.</p>
          </div>
        </div>
      </section>`,
});

pages.push({
  file: "storage-lens.html",
  title: "Storage Lens",
  page: "storage-lens",
  nav: "storage-lens",
  crumb: "Storage Lens",
  main: emptyPanelPage({
    heading: "Storage Lens",
    createLabel: "Create dashboard",
    emptyTitle: "No Storage Lens dashboards",
    emptyBody: "S3 Storage Lens is not available on this local stack. Use CLI and console object listings for local data.",
    odPrefix: "storage-lens",
  }),
});

pages.push({
  file: "batch-operations.html",
  title: "Batch Operations",
  page: "batch-operations",
  nav: "batch-operations",
  crumb: "Batch Operations",
  main: emptyPanelPage({
    heading: "Batch Operations",
    createLabel: "Create job",
    emptyTitle: "No Batch Operations jobs",
    emptyBody: "S3 Batch Operations are not available on this local stack.",
    odPrefix: "batch-operations",
  }),
});

pages.push({
  file: "account-organization-settings.html",
  title: "Account and organization settings",
  page: "account-organization-settings",
  nav: "account-organization-settings",
  crumb: "Account and organization settings",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Account and organization settings</h1>
      <section class="aws-card" data-od-id="bpa-card">
        <div class="aws-card-body">
          <div class="aws-toolbar">
            <h2 class="aws-section-title" style="margin:0;flex:1" data-od-id="bpa-title">Block Public Access settings for this account</h2>
            <button type="button" class="btn btn-normal" data-od-id="btn-edit-bpa" title="To implement" disabled aria-disabled="true">Edit</button>
          </div>
          <p class="aws-desc">Amazon S3 Block Public Access provides settings for access points, buckets, and accounts to help you manage public access to Amazon S3 resources. <a href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html" target="_blank" rel="noopener">Learn more ↗</a></p>
          <dl class="aws-kv" data-od-id="bpa-settings">
            <div><dt>Block all public access</dt><dd><span class="aws-placeholder">[Setting not loaded]</span></dd></div>
            <div><dt>Block public access to buckets and objects granted through new access control lists (ACLs)</dt><dd><span class="aws-placeholder">[Setting not loaded]</span></dd></div>
            <div><dt>Block public access to buckets and objects granted through any access control lists (ACLs)</dt><dd><span class="aws-placeholder">[Setting not loaded]</span></dd></div>
            <div><dt>Block public access to buckets and objects granted through new public bucket or access point policies</dt><dd><span class="aws-placeholder">[Setting not loaded]</span></dd></div>
            <div><dt>Block public and cross-account access to buckets and objects through any public bucket or access point policies</dt><dd><span class="aws-placeholder">[Setting not loaded]</span></dd></div>
          </dl>
        </div>
      </section>
      <section class="aws-card" data-od-id="org-lens-card" style="margin-top:16px">
        <div class="aws-card-body">
          <div class="aws-toolbar">
            <h2 class="aws-section-title" style="margin:0;flex:1" data-od-id="org-title">AWS Organizations settings for Storage Lens <button type="button" class="info" disabled aria-disabled="true" title="To implement">Info</button></h2>
            <button type="button" class="btn btn-normal" disabled aria-disabled="true" data-od-id="btn-edit-trusted" title="To implement">Edit trusted access</button>
          </div>
          <p class="aws-desc">Authorize Storage Lens to access AWS Organizations for organization-wide dashboards. <a href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-lens-trusted-access.html" target="_blank" rel="noopener">Learn more ↗</a></p>
          <dl class="aws-kv">
            <div><dt>Trusted access</dt><dd><span class="aws-placeholder">[Status not loaded]</span></dd></div>
          </dl>
        </div>
      </section>`,
});

const marketplaceCategories = [
  {
    id: "storage-backup",
    title: "Storage, Back-up and Recovery products for S3",
    products: [
      {
        name: "CloudBerry Drive Server Edition",
        vendor: "MSP360",
        rating: "4.2",
        reviews: "18",
        desc: "Mount S3 storage as a local network drive for Windows servers.",
      },
      {
        name: "NetApp Intelligent Services",
        vendor: "NetApp",
        rating: "5.0",
        reviews: "6",
        desc: "Get best-in-class data protection and cyber resilience for S3 data.",
        trial: true,
      },
      {
        name: "Databricks Data Intelligence Platform",
        vendor: "Databricks",
        rating: "4.5",
        reviews: "120",
        desc: "Unify data, analytics, and AI on your S3 lakehouse.",
        trial: true,
      },
    ],
  },
  {
    id: "data-integration",
    title: "Data Integration and Analytics products for S3",
    products: [
      {
        name: "Databricks Data Intelligence Platform",
        vendor: "Databricks",
        rating: "4.5",
        reviews: "120",
        desc: "Process and analyze data stored in Amazon S3 at scale.",
        trial: true,
      },
      {
        name: "Logz.io Open 360 Observability Platform",
        vendor: "Logz.io",
        rating: "5.0",
        reviews: "9",
        desc: "Observability for logs, metrics, and traces with S3 archival.",
        trial: true,
      },
      {
        name: "MongoDB Atlas",
        vendor: "MongoDB",
        rating: "4.4",
        reviews: "40",
        desc: "Fully managed MongoDB with native S3 data movement options.",
      },
    ],
  },
  {
    id: "observability",
    title: "Observability and Monitoring products for S3",
    products: [],
  },
  {
    id: "security",
    title: "Security and Threat Detection products for S3",
    products: [],
  },
  {
    id: "permissions",
    title: "Permissions products for S3",
    products: [],
  },
];

function productCard(p, i) {
  const trial = p.trial ? `<span class="aws-trial">Free Trial</span>` : "";
  return `<article class="aws-product-card" data-od-id="product-${i}">
            <div class="aws-product-icon" aria-hidden="true">${p.name.slice(0, 1)}</div>
            <div class="aws-product-body">
              <h3>${p.name}</h3>
              <p class="vendor">By ${p.vendor}</p>
              <p class="rating"><span class="stars" aria-hidden="true">★★★★★</span> ${p.rating} (${p.reviews}) ${trial}</p>
              <p class="desc">${p.desc}</p>
            </div>
          </article>`;
}

pages.push({
  file: "marketplace-for-s3.html",
  title: "AWS Marketplace for S3",
  page: "marketplace-for-s3",
  nav: "marketplace-for-s3",
  crumb: "AWS Marketplace for S3",
  main: `
      <h1 class="aws-h1" data-od-id="page-title">Search all AWS Marketplace products for S3</h1>
      <label class="aws-marketplace-search" data-od-id="marketplace-search">
        <span aria-hidden="true">⌕</span>
        <input type="search" placeholder="Search all AWS Marketplace products for S3" aria-label="Search all AWS Marketplace products for S3" />
      </label>
      ${marketplaceCategories
        .map((cat) => {
          const body =
            cat.products.length > 0
              ? `<div class="aws-product-grid">
          ${cat.products.map((p, i) => productCard(p, `${cat.id}-${i}`)).join("\n          ")}
        </div>`
              : `<div class="aws-empty-panel"><strong>Products in this category</strong><p>Product cards for this category were not fully visible in the capture used for this mock. Cards were not fully visible in the capture used for this mock.</p></div>`;
          return `
      <section class="aws-marketplace-row" id="${cat.id}" data-od-id="marketplace-${cat.id}">
        <div class="aws-marketplace-row-head">
          <h2>${cat.title}</h2>
        </div>
        ${body}
      </section>`;
        })
        .join("")}`,
});

for (const p of pages) {
  const html = pageShell(p);
  fs.writeFileSync(path.join(screensDir, p.file), html);
  console.log("wrote", p.file);
}

console.log("done", pages.length, "S3 screens");
console.log("Note: run scripts/generate-service-screens.mjs to refresh #319 screens + launcher index.html");
