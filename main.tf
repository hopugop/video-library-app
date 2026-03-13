terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  type    = string
  default = "GuiNogueira"
}

variable "table_name" {
  description = "DynamoDB table name"
  type        = string
  default     = "VideoLibrary"
}

variable "bucket_prefix" {
  description = "Prefix for the S3 bucket name"
  type        = string
  default     = "videolibrary-"
}

provider "aws" {
  region = var.aws_region
}

# ==========================================
# Build Step: Install Node Modules
# ==========================================
resource "terraform_data" "npm_install" {
  # Look for package.json in the root directory, not src/
  #triggers_replace = {
  #  dependencies = filemd5("${path.module}/package.json")
  #}

  provisioner "local-exec" {
    # Run npm install in the root directory
    command = "npm install --omit=dev"
  }
}

# ==========================================
# 1. DynamoDB Table
# ==========================================
resource "aws_dynamodb_table" "video_library" {
  name         = "${var.project}-${var.table_name}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }
}

# ==========================================
# 2. S3 Bucket for Static Website
# ==========================================
resource "aws_s3_bucket" "website" {
  bucket_prefix = lower("${var.project}-${var.bucket_prefix}")
  force_destroy = true
}

resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.website.id
  index_document {
    suffix = "video-library.html"
  }
}

resource "aws_s3_bucket_public_access_block" "website_public_access" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website_policy" {
  bucket     = aws_s3_bucket.website.id
  depends_on = [aws_s3_bucket_public_access_block.website_public_access]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.website.arn}/*"
      },
    ]
  })
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.website.id
  key          = "video-library.html"
  source       = "${path.module}/src/video-library.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/src/video-library.html")
}

# ==========================================
# 3. Lambda Function & IAM
# ==========================================
# Package the Lambda function (Equivalent to Step 1 & 2 in bash)
data "archive_file" "lambda_zip" {
  depends_on = [terraform_data.npm_install]

  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/lambda-function.zip"
  excludes    = ["video-library.html"] # Don't zip the frontend
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project}-video_library_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${var.project}-lambda_dynamodb_access"
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
        "dynamodb:DeleteItem"
      ]
      Effect   = "Allow"
      Resource = aws_dynamodb_table.video_library.arn
    }]
  })
}

resource "aws_lambda_function" "api_handler" {
  function_name    = "${var.project}-VideoLibraryAPI"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.video_library.name
    }
  }
}

# ==========================================
# 4. API Gateway (HTTP API)
# ==========================================
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project}-VideoLibraryAPI"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.api_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ==========================================
# 5. Data Seeding (Step 7 in Bash)
# ==========================================
resource "null_resource" "seed_dynamodb" {
  # This runs the local AWS CLI command just like your bash script did
  # It triggers only when the DynamoDB table is created or recreated
  triggers = {
    table_id = aws_dynamodb_table.video_library.id
  }

  provisioner "local-exec" {
    command = "aws dynamodb batch-write-item --request-items file://${path.module}/sample-data/batch-write-items.json --region ${var.aws_region}"
  }

  depends_on = [aws_dynamodb_table.video_library]
}

# ==========================================
# 6. Deploy Config to EC2
# ==========================================
resource "null_resource" "deploy_migrator_config" {
  triggers = {
    instance_id = aws_instance.app_server.id
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.app_server.public_ip
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    inline = [
      "git clone https://github.com/scylladb/scylla-migrator.git",
      "cat << 'EOF' > /home/ubuntu/scylla-migrator/config.yaml\n${templatefile("${path.module}/config.yaml_DDB.j2", {
        project    = var.project
        table_name = var.table_name
        aws_region = var.aws_region
        private_ip = aws_instance.app_server.private_ip
      })}\nEOF",
      "mkdir -p scylla-migrator/migrator/target/scala-2.13",
      "wget https://github.com/scylladb/scylla-migrator/releases/download/v1.1.2/scylla-migrator-assembly.jar --directory-prefix=scylla-migrator/migrator/target/scala-2.13",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/Dockerfile.t2"
    destination = "/home/ubuntu/scylla-migrator/dockerfiles/spark/Dockerfile"
  }

  provisioner "file" {
    source      = "${path.module}/prepare.sh"
    destination = "/home/ubuntu/prepare.sh"
  }

  provisioner "file" {
    source      = "${path.module}/migrate.sh"
    destination = "/home/ubuntu/migrate.sh"
  }

  #provisioner "local-exec" {
  #  command = "rsync -az ${path.module} ubuntu@${self.public_ip}:/home/ubuntu/"
  #}

  depends_on = [aws_instance.app_server]
}

# ==========================================
# Outputs (Step 5 & Output in Bash)
# ==========================================
output "website_url" {
  description = "The URL to access the Video Library interface"
  value       = "http://${aws_s3_bucket_website_configuration.website_config.website_endpoint}/video-library.html"
}

output "api_endpoint" {
  description = "The API Gateway endpoint to use in the web interface"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}

# ==========================================
# 7. Local File Output (loader)
# ==========================================
resource "local_file" "loader_ip_file" {
  content  = aws_instance.app_server.public_ip
  filename = "${path.module}/loader"
}
