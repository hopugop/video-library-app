# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/24"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "video-library-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "video-library-igw"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "video-library-public-subnet"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "video-library-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group
resource "aws_security_group" "ec2_sg" {
  name        = "video_library_ec2_sg"
  description = "Allow all incoming TCP/UDP and outbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "video-library-ec2-sg"
  }
}

# AMI for Ubuntu 24.04 LTS (Noble Numbat) in us-east-1
data "aws_ami" "ubuntu_24_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "video_library_ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for S3 and DynamoDB Access
resource "aws_iam_policy" "ec2_policy" {
  name        = "video_library_ec2_policy"
  description = "Allow EC2 to access S3 bucket and DynamoDB table"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.website.arn,
          "${aws_s3_bucket.website.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:*"
        ]
        Resource = [
          aws_dynamodb_table.video_library.arn,
          "${aws_dynamodb_table.video_library.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_policy_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "video_library_ec2_profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 Instance
resource "aws_instance" "app_server" {
  ami           = data.aws_ami.ubuntu_24_04.id
  instance_type = "c3.4xlarge"
  subnet_id     = aws_subnet.public.id
  key_name      = "Guilherme"

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  associate_public_ip_address = true

  root_block_device {
    volume_size = 300
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              echo 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDBeApNkbfW6b67jU82ah3QisQXa2wu83NL5lLfXcltKtcuzbO+Nkqub2L5NuAhIYESXVTl9fyLaZju7X9jftySZIG9n1pO4uuIqN7ytijLWH4Gok4XRshkU08m1yZ/bvRlH66veKIAk+tjuKjkJ4i8iwTlQFq9c2pkUHAKxSfdDkBATEn7dUH0I1vnFUATzd0RwUSBPh3mVgGtC3Vut1zT+iC4q0i4H9DY74bfb9lKKJdTDfct9yWvo1pHKLPT0V0VvOg8OffisyVPYDitBCHtOB11oY8KBGTJKPV3aGop1nXwGUyB5pCHt7ayua2cAhhXiAK0EU1eLRWgPJqUaQvZUgrrj3MeFO6skaYEKhTSVCbpbiLwwBJykmE/p4W8BnD7qWj9PzPtDvMs3nOC4xUvlhEUULAnjeymCaXi7iraf7+hK6awUHzcaGIGU9gn7eAGjlPtCsMXEc204vdj8GsAA3eodOqWqhPF+V/j1mHEQTcMVuw5LNwHaKkkHsBQHZ8=' >> /home/ubuntu/.ssh/authorized_keys
              apt update
              apt install docker.io npm git docker-compose -y
              usermod -aG docker ubuntu
              EOF

  tags = {
    Name  = "GuiNogueira-VideoLibraryEC2Instance"
    owner = "guilherme.nogueira"
    Owner = "guilherme.nogueira"
  }
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.app_server.public_ip
}
