output "console_url" {
  value = "http://127.0.0.1:3000"
}

output "unique_prefix" {
  value = local.unique
}

output "s3_bucket" {
  value = aws_s3_bucket.demo.bucket
}

output "lambda_function" {
  value = aws_lambda_function.api.function_name
}

output "sqs_queue_url" {
  value = aws_sqs_queue.demo.id
}

output "sns_topic_arn" {
  value = aws_sns_topic.demo.arn
}

output "dynamodb_table" {
  value = aws_dynamodb_table.demo.name
}

output "kinesis_stream" {
  value = aws_kinesis_stream.demo.name
}

output "eventbridge_rule" {
  value = aws_cloudwatch_event_rule.tick.name
}

output "secrets_arn" {
  value = aws_secretsmanager_secret.demo.arn
}

output "kms_key_id" {
  value = aws_kms_key.demo.key_id
}

output "sfn_arn" {
  value = aws_sfn_state_machine.demo.arn
}

output "ecs_cluster" {
  value = aws_ecs_cluster.demo.name
}

output "ecs_task_definition" {
  value = aws_ecs_task_definition.probe.arn
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.demo.id
}

output "rest_api_invoke_url" {
  value = "${aws_api_gateway_stage.dev.invoke_url}/ping"
}

output "rds_endpoint" {
  value = var.create_rds ? aws_db_instance.pg[0].endpoint : null
}

output "list_in_console" {
  value = <<-EOT
    Open http://127.0.0.1:3000 and check lists for:
    /sqs /sns /events /kinesis /dynamodb /secretsmanager /kms /stepfunctions /ecs /rds /apigateway/rest-apis /lambda
  EOT
}
