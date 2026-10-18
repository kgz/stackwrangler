resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.this.public_key_openssh
}

resource "local_file" "pem" {
  content         = tls_private_key.this.private_key_pem
  filename        = "${path.module}/build/${var.name_prefix}.pem"
  file_permission = "0600"
}

resource "aws_vpc" "this" {
  cidr_block = "10.55.0.0/16"
  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_subnet" "this" {
  vpc_id     = aws_vpc.this.id
  cidr_block = "10.55.1.0/24"
  tags = {
    Name = "${var.name_prefix}-subnet"
  }
}

resource "aws_security_group" "ssh" {
  name   = "${var.name_prefix}-ssh"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = 22
    to_port     = 22
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

resource "aws_instance" "hello" {
  ami                    = "ami-ubuntu-22.04"
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.this.key_name
  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.ssh.id]

  user_data = <<-EOF
    #!/bin/bash
    echo "Hello from awsbox EC2" > /tmp/hello.txt
    date -u > /tmp/boot-time.txt
  EOF

  tags = {
    Name = "${var.name_prefix}-hello"
  }
}

output "instance_id" {
  value = aws_instance.hello.id
}

output "private_ip" {
  value = aws_instance.hello.private_ip
}

output "key_path" {
  value = local_file.pem.filename
}
