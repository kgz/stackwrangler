output "unique_prefix" {
  value = local.unique
}

output "endpoint" {
  value = var.endpoint
}

output "vpc_id" {
  value = aws_vpc.org.id
}

output "subnet_id" {
  value = aws_subnet.org.id
}

output "security_group_id" {
  value = aws_security_group.ecs.id
}

output "s3_bucket" {
  value = aws_s3_bucket.inbox.bucket
}

output "transfer_server_id" {
  value = aws_transfer_server.sftp.id
}

output "transfer_user" {
  value = aws_transfer_user.sftp.user_name
}

output "sftp_private_key_path" {
  value       = local_sensitive_file.sftp_private_key.filename
  description = "OpenSSH private key for SFTP (chmod 600)"
}

output "lambda_function" {
  value = aws_lambda_function.on_upload.function_name
}

output "ecs_cluster" {
  value = aws_ecs_cluster.org.name
}

output "ecs_task_definition" {
  value = aws_ecs_task_definition.ingest.arn
}

output "rds_endpoint" {
  value = var.create_rds ? aws_db_instance.pg[0].endpoint : null
}

output "console_deep_links" {
  value = {
    vpcs     = "${var.console_url}/ec2/vpcs/${aws_vpc.org.id}"
    transfer = "${var.console_url}/transfer"
    lambda   = "${var.console_url}/lambda"
    buckets  = "${var.console_url}/"
    ecs      = "${var.console_url}/ecs/clusters/${aws_ecs_cluster.org.name}"
    rds      = "${var.console_url}/rds"
  }
}

output "verify_cli" {
  value = <<-EOT
    EP=${var.endpoint}
    aws --profile local --endpoint-url "$EP" transfer describe-server --server-id ${aws_transfer_server.sftp.id}
    aws --profile local --endpoint-url "$EP" s3 ls s3://${aws_s3_bucket.inbox.bucket}/
    aws --profile local --endpoint-url "$EP" lambda get-function --function-name ${aws_lambda_function.on_upload.function_name}
    aws --profile local --endpoint-url "$EP" ecs describe-clusters --clusters ${aws_ecs_cluster.org.name}
    ${length(aws_db_instance.pg) > 0 ? "aws --profile local --endpoint-url \"$EP\" rds describe-db-instances --db-instance-identifier ${aws_db_instance.pg[0].identifier}" : "# RDS skipped (create_rds=false)"}
  EOT
}

output "sftp_put_hint" {
  value = <<-EOT
    # Host port from stackwrangler (default 2222). Key: ${local_sensitive_file.sftp_private_key.filename}
    echo hello > /tmp/org-path.txt
    sftp -i ${local_sensitive_file.sftp_private_key.filename} \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
      -P "$${STACKWRANGLER_SFTP_HOST_PORT:-2222}" \
      ${var.sftp_user}@127.0.0.1 <<EOF
    put /tmp/org-path.txt inbox/hello.txt
    bye
    EOF
    aws --profile local --endpoint-url ${var.endpoint} s3 ls s3://${aws_s3_bucket.inbox.bucket}/inbox/
    aws --profile local --endpoint-url ${var.endpoint} s3 cp s3://${aws_s3_bucket.inbox.bucket}/markers/org-path.txt -
  EOT
}

output "run_ecs_hint" {
  value = "aws --profile local --endpoint-url ${var.endpoint} ecs run-task --cluster ${aws_ecs_cluster.org.name} --task-definition ${aws_ecs_task_definition.ingest.family} --launch-type FARGATE --network-configuration 'awsvpcConfiguration={subnets=[${aws_subnet.org.id}],securityGroups=[${aws_security_group.ecs.id}],assignPublicIp=ENABLED}'"
}
