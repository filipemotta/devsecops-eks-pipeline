# Support infrastructure for the pipeline itself: the ECR repo the CI pushes to
# and the S3 bucket that holds build artifacts (SBOMs, scan reports).
# This file is written to PASS `trivy config`; insecure.tf next to it is the
# same intent written to FAIL, so you can watch the gate fire. Terraform is
# valid IaC, and valid IaC deploys insecure resources happily — that is the
# whole reason this gate exists.
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# Customer-managed key so encryption is under our control, not AWS-managed —
# trivy config (AVD-AWS-0132) flags aws:kms without a CMK as a HIGH finding.
resource "aws_kms_key" "artifacts" {
  description             = "CMK for payments-demo artifacts and registry"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

# ECR repository for the signed application image.
resource "aws_ecr_repository" "app" {
  name                 = "payments-demo"
  image_tag_mutability = "IMMUTABLE" # a scanned+signed tag must not be overwritten

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.artifacts.arn
  }
}

# S3 bucket for build artifacts (SBOMs, scan JSON).
resource "aws_s3_bucket" "artifacts" {
  bucket = "payments-demo-artifacts-example"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}
