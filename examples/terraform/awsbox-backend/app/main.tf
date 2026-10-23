resource "aws_sns_topic" "demo" {
  name = var.topic_name
}

output "topic_arn" {
  value = aws_sns_topic.demo.arn
}
