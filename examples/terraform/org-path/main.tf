locals {
  prefix = var.name_prefix
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  unique = "${local.prefix}-${random_id.suffix.hex}"
}

# --- VPC (ECS network; Transfer stays PUBLIC on host SFTP port) ---

resource "aws_vpc" "org" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "${local.unique}-vpc"
  }
}

resource "aws_subnet" "org" {
  vpc_id     = aws_vpc.org.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, 1)
  tags = {
    Name = "${local.unique}-subnet"
  }
}

resource "aws_security_group" "ecs" {
  name   = "${local.unique}-ecs-sg"
  vpc_id = aws_vpc.org.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.unique}-ecs-sg"
  }
}

# --- S3 (LocalEmu :4566 only — never SeaweedFS :8333) ---

resource "aws_s3_bucket" "inbox" {
  bucket = "${local.unique}-inbox"
}

# --- Transfer Family SFTP → S3 home ---

resource "aws_iam_role" "transfer" {
  name = "${local.unique}-xfer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "transfer.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "transfer_s3" {
  name = "s3-home"
  role = aws_iam_role.transfer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      Resource = [
        aws_s3_bucket.inbox.arn,
        "${aws_s3_bucket.inbox.arn}/*",
      ]
    }]
  })
}

resource "aws_transfer_server" "sftp" {
  protocols              = ["SFTP"]
  identity_provider_type = "SERVICE_MANAGED"
  domain                 = "S3"
  tags = {
    Name = "${local.unique}-sftp"
  }
}

resource "aws_transfer_user" "sftp" {
  server_id           = aws_transfer_server.sftp.id
  user_name           = var.sftp_user
  role                = aws_iam_role.transfer.arn
  home_directory_type = "PATH"
  home_directory      = "/${aws_s3_bucket.inbox.bucket}"

  depends_on = [aws_iam_role_policy.transfer_s3]
}

resource "tls_private_key" "sftp" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "sftp_private_key" {
  content         = tls_private_key.sftp.private_key_openssh
  filename        = "${path.module}/build/sftp_id_ed25519"
  file_permission = "0600"
}

resource "aws_transfer_ssh_key" "sftp" {
  server_id = aws_transfer_server.sftp.id
  user_name = aws_transfer_user.sftp.user_name
  body      = tls_private_key.sftp.public_key_openssh
}

# --- Lambda on S3 ObjectCreated:inbox/ ---

data "archive_file" "on_upload" {
  type        = "zip"
  source_file = "${path.module}/src/index.js"
  output_path = "${path.module}/build/on-upload.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${local.unique}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "s3-marker"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.inbox.arn, "${aws_s3_bucket.inbox.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "on_upload" {
  function_name    = "${local.unique}-on-upload"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  filename         = data.archive_file.on_upload.output_path
  source_code_hash = data.archive_file.on_upload.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      MARKER_BUCKET = aws_s3_bucket.inbox.bucket
      MARKER_KEY    = "markers/org-path.txt"
    }
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.on_upload.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.inbox.arn
}

resource "aws_s3_bucket_notification" "inbox" {
  bucket = aws_s3_bucket.inbox.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.on_upload.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inbox/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# --- ECS task (reads S3; env carries RDS endpoint for the path) ---

resource "aws_iam_role" "ecs_task" {
  name = "${local.unique}-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "s3-read"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetObject"]
      Resource = [aws_s3_bucket.inbox.arn, "${aws_s3_bucket.inbox.arn}/*"]
    }]
  })
}

resource "aws_ecs_cluster" "org" {
  name = "${local.unique}-cluster"
}

resource "aws_ecs_task_definition" "ingest" {
  family                   = "${local.unique}-ingest"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "ingest"
    image     = "public.ecr.aws/docker/library/alpine:3.20"
    essential = true
    memory    = 128
    command   = ["sleep", "60"]
    environment = [
      { name = "BUCKET_NAME", value = aws_s3_bucket.inbox.bucket },
      { name = "MARKER_KEY", value = "markers/org-path.txt" },
      {
        name  = "RDS_ENDPOINT"
        value = try(aws_db_instance.pg[0].endpoint, "")
      },
    ]
  }])
}

# --- RDS Postgres (optional; Docker engine behind LocalEmu) ---

resource "aws_db_instance" "pg" {
  count = var.create_rds ? 1 : 0

  identifier          = "${local.unique}-pg"
  engine              = "postgres"
  engine_version      = "15"
  instance_class      = "db.t3.micro"
  allocated_storage   = 20
  db_name             = "orgpath"
  username            = "stackwrangler"
  password            = "stackwranglerpass"
  skip_final_snapshot = true
  publicly_accessible = true
}
