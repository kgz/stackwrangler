resource "aws_vpc" "this" {
  cidr_block = "10.42.0.0/16"
  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_subnet" "this" {
  vpc_id     = aws_vpc.this.id
  cidr_block = "10.42.1.0/24"
  tags = {
    Name = "${var.cluster_name}-subnet"
  }
}

resource "aws_security_group" "tasks" {
  name   = "${var.cluster_name}-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name
}

resource "aws_ecs_task_definition" "nginx" {
  family                   = var.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "nginx:1.27-alpine"
      essential = true
      memory    = 128
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "GREETING", value = "Hello from awsbox ECS" }
      ]
    }
  ])
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "task_definition" {
  value = aws_ecs_task_definition.nginx.arn
}

output "subnet_id" {
  value = aws_subnet.this.id
}

output "security_group_id" {
  value = aws_security_group.tasks.id
}

output "run_hint" {
  value = "aws --endpoint-url ${var.awsbox_endpoint} ecs run-task --cluster ${aws_ecs_cluster.this.name} --task-definition ${aws_ecs_task_definition.nginx.family} --launch-type FARGATE --network-configuration 'awsvpcConfiguration={subnets=[${aws_subnet.this.id}],securityGroups=[${aws_security_group.tasks.id}],assignPublicIp=ENABLED}'"
}
