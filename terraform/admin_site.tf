# ---------------------------------------------------------------------------
# Admin page origin
#
# Separate from the redirect bucket: this one is fully private behind OAC,
# while the redirect bucket has to stay publicly readable for the S3 website
# endpoint to serve 301s (see docs/design.md 3.2).
#
# The page is stored under the key "admin" with no extension so that
# https://<domain>/admin resolves directly. The S3 REST endpoint has no index
# document, so a trailing-slash URL would 404.
#
# Its one asset sits under the key "admin/qrcode.js". S3 has no directories,
# so the object "admin" and the prefix "admin/" are unrelated strings and
# nothing collides. The existing /admin* behaviour routes it to this origin,
# which means the asset is authenticated exactly like the page and no new
# CloudFront behaviour is needed.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "admin" {
  bucket           = format("%s-%s-%s-an", var.admin_bucket_name, data.aws_caller_identity.current.account_id, var.aws_region)
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_public_access_block" "admin" {
  bucket = aws_s3_bucket.admin.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "admin" {
  bucket = aws_s3_bucket.admin.id

  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "admin" {
  name                              = "${var.admin_bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "admin_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.admin.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Unlike the Referer trick on the redirect bucket, this is a real boundary:
    # only this distribution can read the object.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "admin" {
  bucket = aws_s3_bucket.admin.id
  policy = data.aws_iam_policy_document.admin_bucket.json
}

resource "aws_s3_object" "admin_page" {
  bucket       = aws_s3_bucket.admin.id
  key          = "admin"
  source       = "${path.module}/../web/admin.html"
  etag         = filemd5("${path.module}/../web/admin.html")
  content_type = "text/html; charset=utf-8"

  # Short, so a redeploy is visible quickly without an invalidation.
  cache_control = "max-age=60"
}

# QR generation runs entirely in the browser, so this is the whole of it. See
# docs/qr-codes.md 4 for why the library is vendored rather than fetched from a
# CDN, and why it is a separate object rather than inlined into the page.
resource "aws_s3_object" "admin_qrcode_js" {
  bucket = aws_s3_bucket.admin.id
  key    = "admin/qrcode.js"
  source = "${path.module}/../web/vendor/qrcode.js"
  etag   = filemd5("${path.module}/../web/vendor/qrcode.js")

  # Set correctly rather than left to S3's default of binary/octet-stream:
  # a wrong type here is refused outright once a nosniff header exists.
  content_type = "text/javascript; charset=utf-8"

  cache_control = "max-age=60"
}
