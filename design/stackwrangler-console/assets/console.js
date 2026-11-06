/* Shared AWS console chrome + interactions (design mock) */
(function () {
  const ASSET_BASE = document.documentElement.getAttribute("data-asset-base") || "../assets";
  const PAGE = document.body.getAttribute("data-page") || "";
  const NAV = document.body.getAttribute("data-nav") || PAGE;
  const TITLE = document.body.getAttribute("data-title") || "S3";
  const CRUMB = document.body.getAttribute("data-crumb") || TITLE;
  const SERVICE = document.body.getAttribute("data-service") || "s3";

  const REGION = { id: "ap-southeast-2", label: "Asia Pacific (Sydney)" };
  const ACCOUNT = { name: "adshots", id: "445772506418", idDisplay: "4457-7250-6418" };

  const SERVICE_CATEGORIES = [
    "Analytics",
    "Application Integration",
    "Blockchain",
    "Business Applications",
    "Cloud Financial Management",
    "Compute",
    "Containers",
    "Customer Enablement",
    "Database",
    "Developer Tools",
    "End User Computing",
    "Front-end Web & Mobile",
    "Game Development",
    "Internet of Things",
    "Machine Learning",
    "Management & Governance",
    "Media Services",
    "Migration & Transfer",
    "Networking & Content Delivery",
    "Quantum Technologies",
    "Robotics",
    "Satellite",
    "Security, Identity & Compliance",
    "Serverless",
    "Storage",
    "VR & AR",
  ];

  const MARKETPLACE_NAV = [
    { id: "mp-storage", label: "Storage, Back-up and Recovery", href: "marketplace-for-s3.html#storage-backup" },
    { id: "mp-data", label: "Data Integration and Analytics", href: "marketplace-for-s3.html#data-integration" },
    { id: "mp-obs", label: "Observability and Monitoring", href: "marketplace-for-s3.html#observability" },
    { id: "mp-sec", label: "Security and Threat Detection", href: "marketplace-for-s3.html#security" },
    { id: "mp-perm", label: "Permissions", href: "marketplace-for-s3.html#permissions" },
  ];

  const SEARCH_INDEX = [
    { type: "Service", label: "S3", href: "general-purpose-buckets.html" },
    { type: "Service", label: "IAM", href: "iam-users.html" },
    { type: "Service", label: "KMS", href: "kms-keys.html" },
    { type: "Service", label: "Key Management Service", href: "kms-keys.html" },
    { type: "Service", label: "Lambda", href: "lambda-functions.html" },
    { type: "Service", label: "Secrets Manager", href: "secrets-list.html" },
    { type: "Service", label: "CloudWatch", href: "logs-log-groups.html" },
    { type: "Service", label: "Step Functions", href: "sfn-state-machines.html" },
    { type: "Service", label: "Kinesis", href: "kinesis-streams.html" },
    { type: "Service", label: "Kinesis Data Streams", href: "kinesis-streams.html" },
    { type: "Service", label: "SNS", href: "sns-topics.html" },
    { type: "Service", label: "Simple Notification Service", href: "sns-topics.html" },
    { type: "Service", label: "SQS", href: "sqs-queues.html" },
    { type: "Service", label: "Simple Queue Service", href: "sqs-queues.html" },
    { type: "Service", label: "DynamoDB", href: "dynamodb-tables.html" },
    { type: "Service", label: "API Gateway", href: "apigateway-http-apis.html" },
    { type: "Service", label: "CloudFormation", href: "cloudformation-stacks.html" },
    { type: "Service", label: "Transfer Family", href: "transfer-servers.html" },
    { type: "Service", label: "RDS", href: "rds-databases.html" },
    { type: "Service", label: "ECS", href: "ecs-clusters.html" },
    { type: "Service", label: "EC2", href: "ec2-instances.html" },
    { type: "Feature", label: "General purpose buckets", href: "general-purpose-buckets.html" },
    { type: "Feature", label: "Customer managed keys", href: "kms-keys.html" },
    { type: "Feature", label: "Directory buckets", href: "directory-buckets.html" },
    { type: "Feature", label: "Table buckets", href: "table-buckets.html" },
    { type: "Feature", label: "Vector buckets", href: "vector-buckets.html" },
    { type: "Feature", label: "Access Points", href: "access-points.html" },
    { type: "Feature", label: "Access Points for FSx", href: "access-points-fsx.html" },
    { type: "Feature", label: "Access Grants", href: "access-grants.html" },
    { type: "Feature", label: "Storage Lens", href: "storage-lens.html" },
    { type: "Feature", label: "Batch Operations", href: "batch-operations.html" },
    { type: "Feature", label: "IAM Access Analyzer", href: "iam-access-analyzer.html" },
    { type: "Feature", label: "File systems", href: "file-systems.html" },
    { type: "Feature", label: "Account and organization settings", href: "account-organization-settings.html" },
    { type: "Feature", label: "AWS Marketplace for S3", href: "marketplace-for-s3.html" },
    { type: "Feature", label: "IAM Users", href: "iam-users.html" },
    { type: "Feature", label: "Lambda Functions", href: "lambda-functions.html" },
    { type: "Feature", label: "Secrets", href: "secrets-list.html" },
    { type: "Feature", label: "Create function", href: "lambda-create-function.html" },
    { type: "Feature", label: "demo-console-hello", href: "lambda-function-detail.html" },
    { type: "Feature", label: "Log groups", href: "logs-log-groups.html" },
    { type: "Feature", label: "State machines", href: "sfn-state-machines.html" },
    { type: "Feature", label: "Data streams", href: "kinesis-streams.html" },
    { type: "Feature", label: "Topics", href: "sns-topics.html" },
    { type: "Feature", label: "Queues", href: "sqs-queues.html" },
    { type: "Feature", label: "Tables", href: "dynamodb-tables.html" },
    { type: "Feature", label: "HTTP APIs", href: "apigateway-http-apis.html" },
    { type: "Feature", label: "REST APIs", href: "apigateway-rest-apis.html" },
    { type: "Feature", label: "demo-rest", href: "apigateway-rest-api-detail.html" },
    { type: "Feature", label: "Stacks", href: "cloudformation-stacks.html" },
    { type: "Feature", label: "Create stack", href: "cloudformation-create-stack.html" },
    { type: "Feature", label: "Transfer servers", href: "transfer-servers.html" },
    { type: "Feature", label: "Databases", href: "rds-databases.html" },
    { type: "Feature", label: "Create database", href: "rds-create-database.html" },
    { type: "Feature", label: "Clusters", href: "ecs-clusters.html" },
    { type: "Feature", label: "Instances", href: "ec2-instances.html" },
    { type: "Feature", label: "VPCs", href: "ec2-vpcs.html" },
    { type: "Feature", label: "Load balancers", href: "ec2-load-balancers.html" },
    { type: "Bucket", label: "test--apse2-az1--x-s3", href: "bucket-objects.html" },
  ];

  const S3_NAV_TREE = [
    {
      id: "buckets",
      label: "Buckets",
      open: true,
      items: [
        { id: "general-purpose-buckets", label: "General purpose buckets", href: "general-purpose-buckets.html" },
        { id: "directory-buckets", label: "Directory buckets", href: "directory-buckets.html" },
        { id: "table-buckets", label: "Table buckets", href: "table-buckets.html" },
        { id: "vector-buckets", label: "Vector buckets", href: "vector-buckets.html" },
      ],
    },
    {
      id: "files",
      label: "Files",
      open: true,
      items: [{ id: "file-systems", label: "File systems", href: "file-systems.html" }],
    },
    {
      id: "access",
      label: "Access management and security",
      open: true,
      items: [
        { id: "access-points", label: "Access Points", href: "access-points.html" },
        { id: "access-points-fsx", label: "Access Points for FSx", href: "access-points-fsx.html" },
        { id: "access-grants", label: "Access Grants", href: "access-grants.html" },
        { id: "iam-access-analyzer", label: "IAM Access Analyzer", href: "iam-access-analyzer.html" },
      ],
    },
    {
      id: "insights",
      label: "Storage management and insights",
      open: true,
      items: [
        { id: "storage-lens", label: "Storage Lens", href: "storage-lens.html" },
        { id: "batch-operations", label: "Batch Operations", href: "batch-operations.html" },
      ],
    },
  ];

  const S3_FOOT = [
    { id: "account-organization-settings", label: "Account and organization settings", href: "account-organization-settings.html" },
    {
      id: "marketplace-for-s3",
      label: "AWS Marketplace for S3",
      href: "marketplace-for-s3.html",
      expand: true,
      children: MARKETPLACE_NAV,
    },
  ];

  const SERVICE_DEFS = {
    s3: {
      label: "S3",
      home: "general-purpose-buckets.html",
      tree: S3_NAV_TREE,
      foot: S3_FOOT,
    },

    kms: {
      label: "Key Management Service",
      home: "kms-keys.html",
      tree: [
        {
          id: "kms-main",
          label: "Key Management Service",
          open: true,
          items: [{ id: "kms-keys", label: "Customer managed keys", href: "kms-keys.html" }],
        },
      ],
      foot: [],
    },
    iam: {
      label: "IAM",
      home: "iam-users.html",
      tree: [
        {
          id: "access-mgmt",
          label: "Access management",
          open: true,
          items: [{ id: "iam-users", label: "Users", href: "iam-users.html" }],
        },
      ],
      foot: [],
    },
    lambda: {
      label: "Lambda",
      home: "lambda-functions.html",
      tree: [
        {
          id: "lambda-main",
          label: "Lambda",
          open: true,
          items: [{ id: "lambda-functions", label: "Functions", href: "lambda-functions.html" }],
        },
      ],
      foot: [],
    },
    logs: {
      label: "CloudWatch",
      home: "logs-log-groups.html",
      tree: [
        {
          id: "logs-main",
          label: "Logs",
          open: true,
          items: [{ id: "logs-log-groups", label: "Log groups", href: "logs-log-groups.html" }],
        },
      ],
      foot: [],
    },    sfn: {
      label: "Step Functions",
      home: "sfn-state-machines.html",
      tree: [
        {
          id: "sfn-main",
          label: "Step Functions",
          open: true,
          items: [{ id: "sfn-state-machines", label: "State machines", href: "sfn-state-machines.html" }],
        },
      ],
      foot: [],
    },
    secretsmanager: {
      label: "Secrets Manager",
      home: "secrets-list.html",
      tree: [
        {
          id: "secrets-main",
          label: "Secrets",
          open: true,
          items: [{ id: "secrets-list", label: "Secrets", href: "secrets-list.html" }],
        },
      ],
      foot: [],
    },
    kinesis: {
      label: "Kinesis",
      home: "kinesis-streams.html",
      tree: [
        {
          id: "kinesis-main",
          label: "Data streams",
          open: true,
          items: [{ id: "kinesis-streams", label: "Data streams", href: "kinesis-streams.html" }],
        },
      ],
      foot: [],
    },
    sfn: {
      label: "Step Functions",
      home: "sfn-state-machines.html",
      tree: [
        {
          id: "sfn-main",
          label: "Step Functions",
          open: true,
          items: [{ id: "sfn-state-machines", label: "State machines", href: "sfn-state-machines.html" }],
        },
      ],
      foot: [],
    },
    sns: {
      label: "SNS",
      home: "sns-topics.html",
      tree: [
        {
          id: "sns-main",
          label: "SNS",
          open: true,
          items: [{ id: "sns-topics", label: "Topics", href: "sns-topics.html" }],
        },
      ],
      foot: [],
    },
    sqs: {
      label: "SQS",
      home: "sqs-queues.html",
      tree: [
        {
          id: "sqs-main",
          label: "SQS",
          open: true,
          items: [{ id: "sqs-queues", label: "Queues", href: "sqs-queues.html" }],
        },
      ],
      foot: [],
    },
    dynamodb: {
      label: "DynamoDB",
      home: "dynamodb-tables.html",
      tree: [
        {
          id: "dynamodb-main",
          label: "Tables",
          open: true,
          items: [{ id: "dynamodb-tables", label: "Tables", href: "dynamodb-tables.html" }],
        },
      ],
      foot: [],
    },
    apigateway: {
      label: "API Gateway",
      home: "apigateway-http-apis.html",
      tree: [
        {
          id: "apigw-apis",
          label: "APIs",
          open: true,
          items: [
            { id: "apigateway-http-apis", label: "HTTP APIs", href: "apigateway-http-apis.html" },
            { id: "apigateway-rest-apis", label: "REST APIs", href: "apigateway-rest-apis.html" },
          ],
        },
      ],
      foot: [],
    },
    cloudformation: {
      label: "CloudFormation",
      home: "cloudformation-stacks.html",
      tree: [
        {
          id: "cfn-stacks",
          label: "Stacks",
          open: true,
          items: [
            { id: "cloudformation-stacks", label: "Stacks", href: "cloudformation-stacks.html" },
            { id: "cloudformation-create-stack", label: "Create stack", href: "cloudformation-create-stack.html" },
            { id: "cloudformation-stack-detail", label: "Stack detail", href: "cloudformation-stack-detail.html" },
          ],
        },
      ],
      foot: [],
    },
    transfer: {
      label: "AWS Transfer Family",
      home: "transfer-servers.html",
      tree: [
        {
          id: "xfer-servers",
          label: "Servers",
          open: true,
          items: [
            { id: "transfer-servers", label: "Servers", href: "transfer-servers.html" },
            { id: "transfer-server-detail", label: "Server detail", href: "transfer-server-detail.html" },
          ],
        },
      ],
      foot: [],
    },
    rds: {
      label: "RDS",
      home: "rds-databases.html",
      tree: [
        {
          id: "rds-dbs",
          label: "Databases",
          open: true,
          items: [
            { id: "rds-databases", label: "Databases", href: "rds-databases.html" },
            { id: "rds-instance-detail", label: "DB instance", href: "rds-instance-detail.html" },
            { id: "rds-create-database", label: "Create database", href: "rds-create-database.html" },
          ],
        },
      ],
      foot: [],
    },
    ecs: {
      label: "Elastic Container Service",
      home: "ecs-clusters.html",
      tree: [
        {
          id: "ecs-clusters-sec",
          label: "Clusters",
          open: true,
          items: [
            { id: "ecs-clusters", label: "Clusters", href: "ecs-clusters.html" },
            { id: "ecs-cluster-detail", label: "Cluster detail", href: "ecs-cluster-detail.html" },
          ],
        },
      ],
      foot: [],
    },
    ec2: {
      label: "EC2",
      home: "ec2-instances.html",
      tree: [
        {
          id: "ec2-instances-sec",
          label: "Instances",
          open: true,
          items: [{ id: "ec2-instances", label: "Instances", href: "ec2-instances.html" }],
        },
        {
          id: "ec2-network",
          label: "Network & security",
          open: true,
          items: [
            { id: "ec2-vpcs", label: "VPCs", href: "ec2-vpcs.html" },
            { id: "ec2-vpc-detail", label: "VPC detail", href: "ec2-vpc-detail.html" },
          ],
        },
        {
          id: "ec2-lb",
          label: "Load balancing",
          open: true,
          items: [{ id: "ec2-load-balancers", label: "Load balancers", href: "ec2-load-balancers.html" }],
        },
      ],
      foot: [],
    },
  };

  const ACTIVE_SERVICE = SERVICE_DEFS[SERVICE] || SERVICE_DEFS.s3;

  function svg(paths, viewBox) {
    return `<svg width="16" height="16" viewBox="${viewBox || "0 0 24 24"}" aria-hidden="true">${paths}</svg>`;
  }

  const ICONS = {
    grid: svg('<circle cx="5" cy="5" r="1.5"/><circle cx="12" cy="5" r="1.5"/><circle cx="19" cy="5" r="1.5"/><circle cx="5" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="19" cy="12" r="1.5"/><circle cx="5" cy="19" r="1.5"/><circle cx="12" cy="19" r="1.5"/><circle cx="19" cy="19" r="1.5"/>'),
    search: svg('<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/>'),
    gear: svg('<circle cx="12" cy="12" r="3"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>'),
    terminal: svg('<path d="M4 6h16v12H4z"/><path d="M7 10l3 2-3 2M12 14h5"/>'),
    bell: svg('<path d="M6 16h12l-1.5-2.5V10a4.5 4.5 0 10-9 0v3.5L6 16z"/><path d="M10 18a2 2 0 004 0"/>'),
    help: svg('<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 115 1c0 1.5-2.5 2-2.5 3.5"/><circle cx="12" cy="17" r="0.8" fill="currentColor" stroke="none"/>'),
    info: svg('<circle cx="12" cy="12" r="9"/><path d="M12 10v6M12 7.5v.5"/>'),
    refresh: svg('<path d="M20 12a8 8 0 11-2.3-5.6"/><path d="M20 4v5h-5"/>'),
    menu: svg('<path d="M4 7h16M4 12h16M4 17h16"/>'),
    chevL: svg('<path d="M14 6l-6 6 6 6"/>'),
    chevR: svg('<path d="M10 6l6 6-6 6"/>'),
    chevD: svg('<path d="M6 9l6 6 6-6"/>'),
    copy: svg('<rect x="8" y="8" width="10" height="10" rx="1"/><path d="M6 14V6a1 1 0 011-1h8"/>'),
    upload: svg('<path d="M12 16V6M8 10l4-4 4 4"/><path d="M5 18h14"/>'),
    close: svg('<path d="M6 6l12 12M18 6L6 18"/>'),
  };

  function logoMark() {
    return `<svg class="aws-logo-mark" viewBox="0 0 18 18" aria-hidden="true"><rect x="1.5" y="1.5" width="15" height="15" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M9 4.5v9" fill="none" stroke="currentColor" stroke-width="2"/></svg><span class="aws-logo-word">awsbox</span>`;
  }

  function closeMenus(except) {
    document.querySelectorAll("[data-menu].open, .aws-services-panel.open, .aws-search-results.open").forEach((el) => {
      if (el !== except) el.classList.remove("open");
    });
    document.querySelectorAll("[aria-expanded='true']").forEach((el) => {
      if (!except || !except.previousElementSibling || el !== except._owner) {
        if (!except || el.getAttribute("data-owns") !== (except && except.id)) {
          /* keep simple */
        }
      }
    });
    document.querySelectorAll("button[aria-expanded='true']").forEach((btn) => {
      const id = btn.getAttribute("aria-controls");
      if (!except || id !== except.id) btn.setAttribute("aria-expanded", "false");
    });
  }

  function buildTopnav() {
    return `
<header class="aws-topnav" data-od-id="topnav" role="banner">
  <a class="aws-logo" href="../index.html" data-od-id="aws-logo" title="awsbox">${logoMark()}</a>
  <button type="button" class="aws-services-btn" id="btn-services" aria-expanded="false" aria-controls="services-panel" data-od-id="services-btn">
    ${ICONS.grid}<span>Services</span>
  </button>
  <div class="aws-search" data-od-id="global-search">
    <div class="aws-search-field">
      ${ICONS.search}
      <input id="global-search-input" type="search" placeholder="Search" autocomplete="off" aria-label="Search" />
      <span class="aws-search-kbd">Alt+S</span>
      <button type="button" class="aws-icon-btn" id="search-settings" disabled aria-disabled="true" title="To implement" aria-label="Search settings">${ICONS.gear}</button>
    </div>
    <div class="aws-search-results" id="search-results" role="listbox" aria-label="Search results"></div>
  </div>
  <div class="aws-top-actions">
    <div class="aws-pop">
      <button type="button" class="aws-icon-btn" id="btn-cloudshell" aria-expanded="false" aria-controls="menu-cloudshell" title="CloudShell" data-od-id="cloudshell">${ICONS.terminal}</button>
      <div class="aws-menu" id="menu-cloudshell" data-menu>
        <div class="label">CloudShell</div>
        <button type="button" disabled aria-disabled="true" title="To implement">Open CloudShell</button>
        <button type="button" disabled aria-disabled="true" title="To implement">CloudShell preferences</button>
      </div>
    </div>
    <div class="aws-pop">
      <button type="button" class="aws-icon-btn" id="btn-notify" aria-expanded="false" aria-controls="menu-notify" title="Notifications" data-od-id="notifications">${ICONS.bell}</button>
      <div class="aws-menu" id="menu-notify" data-menu>
        <div class="label">Notifications</div>
        <div class="label" style="font-weight:400;text-transform:none;letter-spacing:0">No new notifications</div>
        <div class="sep"></div>
        <button type="button" disabled aria-disabled="true" title="To implement">View all notifications</button>
      </div>
    </div>
    <div class="aws-pop">
      <button type="button" class="aws-icon-btn" id="btn-help" aria-expanded="false" aria-controls="menu-help" title="Help" data-od-id="help">${ICONS.help}</button>
      <div class="aws-menu" id="menu-help" data-menu>
        <div class="label">Help</div>
        <button type="button" disabled aria-disabled="true" title="To implement">Info</button>
        <a href="https://docs.aws.amazon.com/" target="_blank" rel="noopener">Documentation</a>
        <button type="button" disabled aria-disabled="true" title="To implement">Support</button>
      </div>
    </div>
    <div class="aws-pop">
      <button type="button" class="aws-icon-btn" id="btn-settings" aria-expanded="false" aria-controls="menu-settings" title="Settings" data-od-id="settings">${ICONS.gear}</button>
      <div class="aws-menu" id="menu-settings" data-menu>
        <div class="label">Settings</div>
        <button type="button" disabled aria-disabled="true" title="To implement">Unified Settings</button>
        <button type="button" disabled aria-disabled="true" title="To implement">Visual mode</button>
      </div>
    </div>
    <div class="aws-pop">
      <button type="button" class="aws-region-btn" id="btn-region" aria-expanded="false" aria-controls="menu-region" data-od-id="region-selector">
        <span class="line1">${REGION.label} ▾</span>
      </button>
      <div class="aws-menu wide" id="menu-region" data-menu>
        <div class="label">Regions</div>
        <button type="button" data-region="ap-southeast-2">Asia Pacific (Sydney) ap-southeast-2</button>
        <button type="button" data-region="us-east-1">US East (N. Virginia) us-east-1</button>
        <button type="button" data-region="eu-west-1">Europe (Ireland) eu-west-1</button>
        <button type="button" data-region="ap-northeast-1">Asia Pacific (Tokyo) ap-northeast-1</button>
      </div>
    </div>
    <div class="aws-pop">
      <button type="button" class="aws-account-btn" id="btn-account" aria-expanded="false" aria-controls="menu-account" data-od-id="account-menu">
        <span class="line1">Account ID: ${ACCOUNT.idDisplay} ▾</span>
        <span class="line2">${ACCOUNT.name}</span>
      </button>
      <div class="aws-menu aws-account-panel" id="menu-account" data-menu data-od-id="account-panel">
        <div class="acct-row">
          <span class="acct-k">Account ID</span>
          <span class="acct-v">${ACCOUNT.idDisplay} <button type="button" class="btn-icon acct-copy" disabled aria-disabled="true" aria-label="Copy account ID" title="To implement">${ICONS.copy}</button></span>
        </div>
        <div class="acct-row">
          <span class="acct-k">Account name</span>
          <span class="acct-v">${ACCOUNT.name}</span>
        </div>
        <div class="acct-row">
          <span class="acct-k">Account color</span>
          <span class="acct-v"><span class="acct-swatch" aria-hidden="true"></span> Default</span>
        </div>
        <div class="acct-row">
          <span class="acct-k">Federated user</span>
          <span class="acct-v">${ACCOUNT.name}</span>
        </div>
        <div class="sep"></div>
        <button type="button" disabled aria-disabled="true" title="To implement">Account</button>
        <button type="button" disabled aria-disabled="true" title="To implement">Organization</button>
        <button type="button" disabled aria-disabled="true" title="To implement">Service Quotas</button>
        <button type="button" disabled aria-disabled="true" title="To implement">Billing and Cost Management</button>
        <div class="sep"></div>
        <div class="acct-actions">
          <button type="button" class="btn btn-normal" disabled aria-disabled="true" title="To implement">Turn on multi-session support</button>
          <button type="button" class="btn btn-normal" disabled aria-disabled="true" title="To implement">Switch role</button>
          <button type="button" class="btn btn-primary" disabled aria-disabled="true" title="To implement">Sign out</button>
        </div>
      </div>
    </div>
  </div>
</header>
<nav class="aws-services-panel" id="services-panel" data-od-id="services-menu" hidden></nav>
<nav class="aws-favorites" data-od-id="favorites-bar" aria-label="Favorites">
  ${[
    ["EC2", "EC2", "ec2-instances.html"],
    ["ECS", "Elastic Container Service", "ecs-clusters.html"],
    ["IAM", "IAM", "iam-users.html"],
    ["KMS", "KMS", "kms-keys.html"],
    ["λ", "Lambda", "lambda-functions.html"],
    ["S3", "S3", "general-purpose-buckets.html"],
  ]
    .map(([abbr, name, href]) =>
      href
        ? `<a class="aws-fav" href="${href}"><span class="aws-fav-icon">${abbr}</span>${name}</a>`
        : `<button type="button" class="aws-fav" disabled aria-disabled="true" title="To implement"><span class="aws-fav-icon">${abbr}</span>${name}</button>`
    )
    .join("")}
</nav>
<div class="aws-service-bar" data-od-id="service-header">
  <button type="button" class="burger" id="btn-sidebar-toggle" aria-label="Toggle navigation">${ICONS.menu}</button>
  <div class="aws-crumbs" data-od-id="breadcrumbs">
    <a href="${ACTIVE_SERVICE.home}">${ACTIVE_SERVICE.label}</a>
    <span class="sep">›</span>
    <span class="current">${CRUMB}</span>
  </div>
  <button type="button" class="aws-page-info" id="btn-page-info" title="Page info" aria-label="Page info" data-od-id="page-info">${ICONS.info}</button>
</div>`;
  }

  function buildSidebar() {
    const marketplaceOpen = NAV === "marketplace-for-s3" || String(NAV).startsWith("mp-");
    const tree = ACTIVE_SERVICE.tree || [];
    const footItems = ACTIVE_SERVICE.foot || [];
    const sections = tree
      .map((sec) => {
        const items = sec.items
          .map((it) => {
            const active = it.id === NAV ? " active" : "";
            if (it.omit) return "";
            if (it.disabled) {
              return `<button type="button" class="aws-nav-link${active}" disabled aria-disabled="true" title="To implement" data-od-id="nav-${it.id}">${it.label}</button>`;
            }
            return `<a class="aws-nav-link${active}" href="${it.href}" data-od-id="nav-${it.id}">${it.label}</a>`;
          })
          .join("");
        return `<details class="aws-nav-section" ${sec.open ? "open" : ""} data-od-id="nav-section-${sec.id}">
        <summary><span class="caret">▾</span>${sec.label}</summary>${items}</details>`;
      })
      .join("");
    const foot = footItems
      .map((it) => {
        const active = it.id === NAV ? " active" : "";
        if (it.expand) {
          const kids = (it.children || [])
            .map(
              (c) =>
                `<a class="aws-nav-link aws-nav-sub${c.id === NAV ? " active" : ""}" href="${c.href}" data-od-id="nav-${c.id}">${c.label}</a>`
            )
            .join("");
          return `<details class="aws-nav-section aws-nav-marketplace" ${marketplaceOpen ? "open" : ""} data-od-id="nav-section-marketplace">
          <summary><span class="caret">▾</span><a class="aws-nav-summary-link${active}" href="${it.href}" data-od-id="nav-${it.id}">${it.label}</a></summary>
          ${kids}
        </details>`;
        }
        const ext = it.ext ? `<span class="ext">›</span>` : "";
        return `<a class="aws-nav-link${active}" href="${it.href}" data-od-id="nav-${it.id}">${it.label}${ext}</a>`;
      })
      .join("");
    const sid = `${SERVICE}-sidebar`;
    return `
<aside class="aws-sidebar" data-od-id="${sid}" aria-label="${ACTIVE_SERVICE.label}">
  <div class="aws-sidebar-head">
    <span>${ACTIVE_SERVICE.label}</span>
    <button type="button" id="btn-collapse-sidebar" aria-label="Collapse navigation">${ICONS.chevL}</button>
  </div>
  ${sections}
  ${foot ? `<div class="aws-nav-foot">${foot}</div>` : ""}
</aside>`;
  }

  function buildServicesPanel() {
    const cats = SERVICE_CATEGORIES.map(
      (name) =>
        `<button type="button" class="svc-cat" disabled aria-disabled="true" title="To implement">${name}</button>`
    ).join("");
    const recent = [
      ["S3", "S3", "Scalable Storage in the Cloud", "general-purpose-buckets.html"],
      ["IAM", "IAM", "Manage access to awsbox resources", "iam-users.html"],
      ["λ", "Lambda", "Run code without thinking about servers", "lambda-functions.html"],
      ["SM", "Secrets Manager", "Manage secrets and credentials", "secrets-list.html"],
      ["CFN", "CloudFormation", "Model and provision resources", "cloudformation-stacks.html"],
      ["KIN", "Kinesis", "Real-time data streams", "kinesis-streams.html"],
      ["SNS", "SNS", "Pub/sub notifications", "sns-topics.html"],
      ["SQS", "SQS", "Managed message queues", "sqs-queues.html"],
      ["DDB", "DynamoDB", "NoSQL key-value and document store", "dynamodb-tables.html"],
      ["EC2", "EC2", "Virtual servers in the cloud", "ec2-instances.html"],
      ["RDS", "RDS", "Managed relational databases", "rds-databases.html"],
    ]
      .map(([abbr, name, desc, href], i) =>
        href
          ? `<a class="svc-tile" href="${href}" data-od-id="svc-recent-${i}">
    <span class="aws-fav-icon">${abbr}</span>
    <span>
      <strong>${name}</strong>
      <span class="svc-tile-desc">${desc}</span>
    </span>
  </a>`
          : `<button type="button" class="svc-tile" disabled aria-disabled="true" title="To implement" data-od-id="svc-recent-${i}">
    <span class="aws-fav-icon">${abbr}</span>
    <span>
      <strong>${name}</strong>
      <span class="svc-tile-desc">${desc}</span>
    </span>
  </button>`
      )
      .join("");
    return `
<div class="svc-rail" data-od-id="services-rail">
  <button type="button" class="svc-rail-item active" data-svc-view="recent">Recently visited</button>
  <button type="button" class="svc-rail-item" disabled aria-disabled="true" title="To implement">Favorites</button>
  <button type="button" class="svc-rail-item" disabled aria-disabled="true" title="To implement">All applications</button>
  <button type="button" class="svc-rail-item" disabled aria-disabled="true" title="To implement">All services</button>
  <div class="svc-rail-cats">${cats}</div>
</div>
<div class="svc-main" data-od-id="services-main">
  <div class="svc-main-head">
    <h2>Recently visited</h2>
    <button type="button" class="aws-icon-btn" id="btn-services-close" aria-label="Close services">${ICONS.close}</button>
  </div>
  ${recent}
</div>`;
  }

  function mountChrome() {
    const root = document.getElementById("aws-chrome");
    if (!root) return;
    root.innerHTML = buildTopnav();

    const panel = document.getElementById("services-panel");
    if (panel) {
      panel.hidden = false;
      panel.innerHTML = buildServicesPanel();
    }

    const shell = document.getElementById("aws-shell");
    if (shell && !shell.querySelector(".aws-sidebar")) {
      shell.insertAdjacentHTML("afterbegin", buildSidebar());
    }
  }

  function wireMenus() {
    function toggle(btn, menu) {
      const open = !menu.classList.contains("open");
      closeMenus(open ? menu : null);
      menu.classList.toggle("open", open);
      btn.setAttribute("aria-expanded", open ? "true" : "false");
    }

    const pairs = [
      ["btn-cloudshell", "menu-cloudshell"],
      ["btn-notify", "menu-notify"],
      ["btn-help", "menu-help"],
      ["btn-settings", "menu-settings"],
      ["btn-region", "menu-region"],
      ["btn-account", "menu-account"],
    ];
    pairs.forEach(([bid, mid]) => {
      const btn = document.getElementById(bid);
      const menu = document.getElementById(mid);
      if (!btn || !menu) return;
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        toggle(btn, menu);
      });
    });

    const svcBtn = document.getElementById("btn-services");
    const svcPanel = document.getElementById("services-panel");
    if (svcBtn && svcPanel) {
      svcBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        const open = !svcPanel.classList.contains("open");
        closeMenus(open ? svcPanel : null);
        svcPanel.classList.toggle("open", open);
        svcBtn.setAttribute("aria-expanded", open ? "true" : "false");
      });
      const closeSvc = document.getElementById("btn-services-close");
      if (closeSvc) {
        closeSvc.addEventListener("click", (e) => {
          e.stopPropagation();
          svcPanel.classList.remove("open");
          svcBtn.setAttribute("aria-expanded", "false");
        });
      }
    }

    document.addEventListener("click", () => closeMenus(null));
    document.querySelectorAll("[data-menu], .aws-services-panel, .aws-search").forEach((el) => {
      el.addEventListener("click", (e) => e.stopPropagation());
    });

    document.body.addEventListener("click", (e) => {
      const dead = e.target.closest('[aria-disabled="true"], [disabled]');
      if (dead && dead.closest("a, button")) {
        e.preventDefault();
        return;
      }
      const region = e.target.closest("[data-region]");
      if (region) {
        const label = region.textContent.trim();
        const btn = document.getElementById("btn-region");
        if (btn) btn.querySelector(".line1").textContent = label.replace(/\s+[a-z]{2}-[a-z]+-\d+\s*$/i, "").trim() + " ▾";
        closeMenus(null);
      }
    });

    const pageInfo = document.getElementById("btn-page-info");
    if (pageInfo) {
      pageInfo.disabled = true;
      pageInfo.setAttribute("aria-disabled", "true");
      pageInfo.title = "To implement";
    }

    const collapse = document.getElementById("btn-collapse-sidebar");
    const burger = document.getElementById("btn-sidebar-toggle");
    const shell = document.getElementById("aws-shell");
    if (collapse && shell) {
      collapse.addEventListener("click", () => shell.classList.toggle("sidebar-collapsed"));
    }
    if (burger && shell) {
      burger.addEventListener("click", () => shell.classList.toggle("sidebar-open-mobile"));
    }
  }

  function wireSearch() {
    const input = document.getElementById("global-search-input");
    const results = document.getElementById("search-results");
    if (!input || !results) return;

    function render(q) {
      const query = q.trim().toLowerCase();
      if (!query) {
        results.classList.remove("open");
        results.innerHTML = "";
        return;
      }
      const hits = SEARCH_INDEX.filter((item) => item.label.toLowerCase().includes(query)).slice(0, 12);
      if (!hits.length) {
        results.innerHTML = `<div class="sr-group">No matches for “${q.replace(/[<>]/g, "")}”</div>`;
        results.classList.add("open");
        return;
      }
      const byType = {};
      hits.forEach((h) => {
        (byType[h.type] = byType[h.type] || []).push(h);
      });
      results.innerHTML = Object.keys(byType)
        .map((type) => {
          const rows = byType[type]
            .map(
              (h) =>
                `<a href="${h.href}" role="option"><span>${h.label}</span><span class="sr-meta">${h.type}</span></a>`
            )
            .join("");
          return `<div class="sr-group">${type}</div>${rows}`;
        })
        .join("");
      results.classList.add("open");
    }

    input.addEventListener("input", () => render(input.value));
    input.addEventListener("focus", () => {
      if (input.value.trim()) render(input.value);
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        results.classList.remove("open");
        input.blur();
      }
    });

    document.addEventListener("keydown", (e) => {
      if (e.altKey && (e.key === "s" || e.key === "S")) {
        e.preventDefault();
        input.focus();
        input.select();
      }
    });
  }

  function wirePageActions() {
    document.querySelectorAll("[data-action]").forEach((el) => {
      el.disabled = true;
      el.setAttribute("aria-disabled", "true");
      el.title = "To implement";
      el.removeAttribute("data-action");
    });

    const find = document.querySelector("[data-find-table]");
    if (find) {
      const table = document.querySelector(find.getAttribute("data-find-table"));
      find.addEventListener("input", () => {
        const q = find.value.trim().toLowerCase();
        if (!table) return;
        table.querySelectorAll("tbody tr[data-name]").forEach((row) => {
          const name = row.getAttribute("data-name") || "";
          row.style.display = !q || name.toLowerCase().includes(q) ? "" : "none";
        });
      });
    }

    document.querySelectorAll("[data-tabs]").forEach((root) => {
      const tabs = root.querySelectorAll("[data-tab]");
      const panels = root.querySelectorAll("[data-tab-panel]");
      tabs.forEach((tab) => {
        tab.addEventListener("click", (e) => {
          e.preventDefault();
          const id = tab.getAttribute("data-tab");
          tabs.forEach((t) => {
            const on = t.getAttribute("data-tab") === id;
            t.classList.toggle("active", on);
            if (on) t.setAttribute("aria-current", "page");
            else t.removeAttribute("aria-current");
          });
          panels.forEach((p) => {
            p.hidden = p.getAttribute("data-tab-panel") !== id;
          });
        });
      });
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    mountChrome();
    wireMenus();
    wireSearch();
    wirePageActions();
  });
})();
