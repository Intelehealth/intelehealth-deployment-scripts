terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

# ── Provider ──────────────────────────────────────────────────────────────────
provider "aws" {
  region = "ap-south-1" # Mumbai
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "key_pair_name" {
  description = "Name of an existing EC2 Key Pair for SSH access"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to reach port 22 (restrict to your IP in production)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "intelehealth-server"
}

# ── Data: latest Ubuntu 22.04 LTS AMI (Canonical) ────────────────────────────
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Security Group ────────────────────────────────────────────────────────────
resource "aws_security_group" "main" {
  name        = "${var.instance_name}-sg"
  description = "Security group for ${var.instance_name}"

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # HTTP
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # App port 3004
  ingress {
    description = "App port 3004"
    from_port   = 3004
    to_port     = 3004
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Prometheus / monitoring port 9090
  ingress {
    description = "Prometheus / monitoring 9090"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MySQL / MariaDB — restrict to VPC or trusted CIDRs in production
  ingress {
    description = "MySQL 3306"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # ⚠️  Tighten this in production
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "main" {
  ami                         = data.aws_ami.ubuntu_2204.id
  instance_type               = "t3a.large"
  key_name                    = var.key_pair_name
  vpc_security_group_ids      = [aws_security_group.main.id]
  associate_public_ip_address = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30   # GiB — adjust as needed
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only (security best practice)
  }

  tags = {
    Name        = var.instance_name
    Environment = "production"
    OS          = "Ubuntu-22.04"
  }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
resource "aws_eip" "main" {
  instance = aws_instance.main.id
  domain   = "vpc"

  tags = {
    Name = "${var.instance_name}-eip"
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.main.id
}

output "public_ip" {
  description = "Elastic (static) public IP"
  value       = aws_eip.main.public_ip
}

output "public_dns" {
  description = "Public DNS of the instance"
  value       = aws_instance.main.public_dns
}

output "ami_used" {
  description = "Ubuntu 22.04 AMI resolved at apply time"
  value       = data.aws_ami.ubuntu_2204.id
}
