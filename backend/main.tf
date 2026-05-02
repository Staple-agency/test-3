# AdvoHQ — AWS Infrastructure Setup
# This file documents the AWS resources needed.
# You can provision these manually via AWS Console or use the Terraform config below.

#──────────────────────────────────────────────────────────────────────────────
# 1. AWS RDS (PostgreSQL) — Managed Database
#──────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-south-1"   # Mumbai — change to your preferred region
}

# VPC Security Group — allow PostgreSQL from Vercel egress IPs
resource "aws_security_group" "rds_sg" {
  name        = "advohq-rds-sg"
  description = "Allow PostgreSQL from Vercel"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # Narrow this to Vercel IP ranges in production
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS PostgreSQL instance
resource "aws_db_instance" "advohq_db" {
  identifier             = "advohq-db"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t3.micro"    # Free tier eligible; upgrade for production
  allocated_storage      = 20
  max_allocated_storage  = 100              # Auto-scaling storage up to 100 GB

  db_name  = "advohq"
  username = "advohq_admin"
  password = var.db_password               # Set via terraform.tfvars or env

  publicly_accessible    = true            # Set false and use VPC peering for production
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = false
  final_snapshot_identifier = "advohq-final"

  backup_retention_period = 7              # 7-day automated backups
  backup_window           = "03:00-04:00"  # UTC
  maintenance_window      = "Mon:04:00-Mon:05:00"

  storage_encrypted = true
  deletion_protection = true

  tags = { Project = "AdvoHQ", Environment = "production" }
}

output "rds_endpoint" {
  value = aws_db_instance.advohq_db.endpoint
}

#──────────────────────────────────────────────────────────────────────────────
# 2. AWS S3 — File Storage
#──────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "advohq_files" {
  bucket = "advohq-files-${random_id.suffix.hex}"
  tags   = { Project = "AdvoHQ" }
}

resource "random_id" "suffix" { byte_length = 4 }

resource "aws_s3_bucket_versioning" "files_versioning" {
  bucket = aws_s3_bucket.advohq_files.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "files_enc" {
  bucket = aws_s3_bucket.advohq_files.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_cors_configuration" "files_cors" {
  bucket = aws_s3_bucket.advohq_files.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["https://advohq.vercel.app", "http://localhost:3000"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "files_lifecycle" {
  bucket = aws_s3_bucket.advohq_files.id
  rule {
    id     = "delete-incomplete-uploads"
    status = "Enabled"
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# Block all public access (files accessed via pre-signed URLs only)
resource "aws_s3_bucket_public_access_block" "files_block" {
  bucket                  = aws_s3_bucket.advohq_files.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#──────────────────────────────────────────────────────────────────────────────
# 3. IAM User for Vercel (least-privilege)
#──────────────────────────────────────────────────────────────────────────────

resource "aws_iam_user" "vercel_api" {
  name = "advohq-vercel-api"
  tags = { Project = "AdvoHQ" }
}

resource "aws_iam_access_key" "vercel_api_key" {
  user = aws_iam_user.vercel_api.name
}

resource "aws_iam_user_policy" "vercel_s3_policy" {
  name = "advohq-s3-access"
  user = aws_iam_user.vercel_api.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:HeadObject"]
      Resource = "${aws_s3_bucket.advohq_files.arn}/cases/*"
    }]
  })
}

output "iam_access_key_id"     { value = aws_iam_access_key.vercel_api_key.id }
output "iam_secret_access_key" { value = aws_iam_access_key.vercel_api_key.secret; sensitive = true }
output "s3_bucket_name"        { value = aws_s3_bucket.advohq_files.bucket }

variable "db_password" { sensitive = true }
