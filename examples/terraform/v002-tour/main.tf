locals {
  prefix = var.name_prefix
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  unique = "${local.prefix}-${random_id.suffix.hex}"
}

# --- Object storage + Lambda (console lists; Lambda host-map path is VpcConfig-only) ---

data "archive_file" "fn" {
  type        = "zip"
  source_file = "${path.module}/src/index.js"
  output_path = "${path.module}/build/function.zip"
}

resource "aws_s3_bucket" "demo" {
  bucket = "${local.unique}-bucket"
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
  name = "${local.unique}-lambda"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.demo.arn, "${aws_s3_bucket.demo.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sns:Publish", "kinesis:PutRecord"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "api" {
  function_name    = "${local.unique}-fn"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout          = 30
  depends_on       = [aws_iam_role_policy.lambda]
}

# --- Messaging (#167 SQS · #172 SNS · #173 EventBridge · #178 Kinesis) ---

resource "aws_sqs_queue" "demo" {
  name = "${local.unique}-q"
}

resource "aws_sns_topic" "demo" {
  name = "${local.unique}-topic"
}

resource "aws_sns_topic_subscription" "q" {
  topic_arn = aws_sns_topic.demo.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.demo.arn
}

resource "aws_sqs_queue_policy" "sns" {
  queue_url = aws_sqs_queue.demo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal  = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.demo.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.demo.arn } }
    }]
  })
}

resource "aws_kinesis_stream" "demo" {
  name        = "${local.unique}-stream"
  shard_count = 1
}

resource "aws_cloudwatch_event_rule" "tick" {
  name                = "${local.unique}-tick"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.tick.name
  target_id = "sns"
  arn       = aws_sns_topic.demo.arn
}

resource "aws_sns_topic_policy" "events" {
  arn = aws_sns_topic.demo.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal  = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.demo.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.tick.arn } }
    }]
  })
}

# --- Data (#174 DynamoDB · #145 RDS) ---

resource "aws_dynamodb_table" "demo" {
  name         = "${local.unique}-ddb"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_db_instance" "pg" {
  count = var.create_rds ? 1 : 0

  identifier     = "${local.unique}-pg"
  engine         = "postgres"
  engine_version = "15"
  instance_class = "db.t3.micro"
  allocated_storage = 20

  db_name  = "app"
  username = "stackwrangler"
  password = "stackwranglerpass"
  # LocalEmu Docker backend; skip AWS-style final snapshot.
  skip_final_snapshot = true
  publicly_accessible = true
}

# --- Secrets / KMS (#176 · #177) ---

resource "aws_kms_key" "demo" {
  description             = "${local.unique} demo CMK"
  deletion_window_in_days = 7
}

resource "aws_secretsmanager_secret" "demo" {
  name       = "${local.unique}/demo"
  kms_key_id = aws_kms_key.demo.arn
}

resource "aws_secretsmanager_secret_version" "demo" {
  secret_id     = aws_secretsmanager_secret.demo.id
  secret_string = jsonencode({ username = "demo", password = "demo-secret" })
}

# --- Step Functions (#175) ---

resource "aws_iam_role" "sfn" {
  name = "${local.unique}-sfn"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_sfn_state_machine" "demo" {
  name     = "${local.unique}-sm"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "v0.0.2 tour Pass"
    StartAt = "Hello"
    States = {
      Hello = {
        Type   = "Pass"
        Result = { ok = true }
        End    = true
      }
    }
  })
}

# --- ECS task role path (#146 list/create · #154/#254 task-role) ---

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
  name = "${local.unique}-ecs-task"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetObject"]
      Resource = [aws_s3_bucket.demo.arn, "${aws_s3_bucket.demo.arn}/*"]
    }]
  })
}

resource "aws_ecs_cluster" "demo" {
  name = "${local.unique}-cluster"
}

resource "aws_ecs_task_definition" "probe" {
  family                   = "${local.unique}-probe"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "probe"
    image     = "public.ecr.aws/docker/library/alpine:3.20"
    essential = true
    memory    = 128
    command   = ["sleep", "30"]
  }])
}

# --- API Gateway REST (#189) ---

resource "aws_api_gateway_rest_api" "demo" {
  name = "${local.unique}-rest"
}

resource "aws_api_gateway_resource" "ping" {
  rest_api_id = aws_api_gateway_rest_api.demo.id
  parent_id   = aws_api_gateway_rest_api.demo.root_resource_id
  path_part   = "ping"
}

resource "aws_api_gateway_method" "ping_get" {
  rest_api_id   = aws_api_gateway_rest_api.demo.id
  resource_id   = aws_api_gateway_resource.ping.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "ping_mock" {
  rest_api_id = aws_api_gateway_rest_api.demo.id
  resource_id = aws_api_gateway_resource.ping.id
  http_method = aws_api_gateway_method.ping_get.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "ping_200" {
  rest_api_id = aws_api_gateway_rest_api.demo.id
  resource_id = aws_api_gateway_resource.ping.id
  http_method = aws_api_gateway_method.ping_get.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "ping_200" {
  rest_api_id = aws_api_gateway_rest_api.demo.id
  resource_id = aws_api_gateway_resource.ping.id
  http_method = aws_api_gateway_method.ping_get.http_method
  status_code = aws_api_gateway_method_response.ping_200.status_code
  depends_on  = [aws_api_gateway_integration.ping_mock]
  response_templates = {
    "application/json" = jsonencode({ ok = true, tour = "v0.0.2" })
  }
}

resource "aws_api_gateway_deployment" "demo" {
  rest_api_id = aws_api_gateway_rest_api.demo.id
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_integration.ping_mock.id,
      aws_api_gateway_integration_response.ping_200.id,
    ]))
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [
    aws_api_gateway_integration.ping_mock,
    aws_api_gateway_integration_response.ping_200,
  ]
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.demo.id
  rest_api_id   = aws_api_gateway_rest_api.demo.id
  stage_name    = "dev"
}
