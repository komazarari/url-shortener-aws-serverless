# ---------------------------------------------------------------------------
# S3 for storing objects to redirect by metadata
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "redirect" {
  bucket              = var.redirect_bucket_name
  bucket_namespace    = "global"
  force_destroy       = false
  object_lock_enabled = false

  lifecycle {
    prevent_destroy = true
  }
}

# To enable 301 redirect by 'x-amz-website-redirect-location'
resource "aws_s3_bucket_website_configuration" "redirect" {
  bucket = var.redirect_bucket_name

  index_document {
    suffix = "index.html"
  }
}

# ---------------------------------------------------------------------------
# Website endpoints cannot use OAC, so anonymous s3:GetObject must stay allowed.
# Instead, require the secret Referer that CloudFront injects.
#
# NOTE: arbitrary header names cannot be used as a policy condition.
#       aws:Referer and aws:UserAgent are the only HTTP headers with an IAM
#       condition key. See docs/design.md 3.2.
#
# Two-phase rollout via enforce_origin_secret:
#   1st apply (false) - CloudFront starts sending Referer; policy unchanged
#   2nd apply (true)  - policy starts requiring it
# ---------------------------------------------------------------------------

locals {
  # jsonencode emits `"Condition": null` for a null value, so grow the key
  # conditionally with merge() instead of using a ternary on Condition itself.
  redirect_policy_statement = merge(
    {
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:::${var.redirect_bucket_name}/*"
    },
    var.enforce_origin_secret ? {
      Condition = {
        StringEquals = {
          "aws:Referer" = var.origin_secret
        }
      }
    } : {}
  )
}

resource "aws_s3_bucket_policy" "redirect" {
  bucket = var.redirect_bucket_name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.redirect_policy_statement]
  })
}

resource "aws_s3_bucket_public_access_block" "redirect" {
  bucket = var.redirect_bucket_name

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "redirect" {
  bucket = var.redirect_bucket_name

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "redirect" {
  bucket = var.redirect_bucket_name

  rule {
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "redirect" {
  bucket = var.redirect_bucket_name
  versioning_configuration {
    status = "Enabled"
  }
}
