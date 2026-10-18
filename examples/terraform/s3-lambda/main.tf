data "archive_file" "fn" {
  type        = "zip"
  source_file = "${path.module}/src/index.js"
  output_path = "${path.module}/build/function.zip"
}

resource "aws_s3_bucket" "demo" {
  bucket = var.bucket_name
}

resource "aws_iam_role" "lambda" {
  name = "${var.function_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "${var.function_name}-s3"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.demo.arn,
          "${aws_s3_bucket.demo.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "writer" {
  function_name = var.function_name
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
  filename      = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout       = 30

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.demo.bucket
    }
  }

  depends_on = [aws_iam_role_policy.lambda_s3]
}

output "bucket_name" {
  value = aws_s3_bucket.demo.bucket
}

output "function_name" {
  value = aws_lambda_function.writer.function_name
}

output "invoke_hint" {
  value = "aws --endpoint-url ${var.awsbox_endpoint} lambda invoke --function-name ${var.function_name} --payload '{\"ping\":true}' --cli-binary-format raw-in-base64-out /tmp/out.json && aws --endpoint-url ${var.awsbox_endpoint} s3 ls s3://${var.bucket_name}/writes/"
}
