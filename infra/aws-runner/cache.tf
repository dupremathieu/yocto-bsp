resource "aws_s3_bucket" "yocto_cache" {
  bucket_prefix = "${var.prefix}-cache-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "yocto_cache" {
  bucket                  = aws_s3_bucket.yocto_cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "yocto_cache" {
  bucket = aws_s3_bucket.yocto_cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "yocto_cache" {
  bucket = aws_s3_bucket.yocto_cache.id
  rule {
    id     = "evaluation-cache-expiry"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_iam_role_policy" "yocto_cache" {
  name = "yocto-cache"
  role = module.github_runner.runners.role_runner[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.yocto_cache.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.yocto_cache.arn}/*"
      }
    ]
  })
}
