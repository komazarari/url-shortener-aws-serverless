# ---------------------------------------------------------------------------
# Registration API (Lambda + Function URL)
#
# NOT wired into CloudFront yet. Until Lambda@Edge OIDC exists, adding an
# /api/* behaviour would expose an unauthenticated link creator on a public
# domain. AuthType = AWS_IAM means only signed callers can reach it.
#
# Test with: scripts/call_api.py
# ---------------------------------------------------------------------------

data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/api"
  output_path = "${path.module}/.build/api.zip"

  excludes = [
    "test_handler.py",
    "__pycache__",
  ]
}

data "aws_iam_policy_document" "api_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "${var.api_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.api_assume_role.json
}

data "aws_iam_policy_document" "api" {
  # HeadObject is covered by GetObject. No DeleteObject: the API cannot remove
  # links.
  statement {
    sid       = "ReadWriteRedirectObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.redirect.arn}/*"]
  }

  # Do not remove. Without s3:ListBucket, HeadObject on a key that does not
  # exist returns 403 rather than 404 -- S3 hides existence from callers who
  # cannot list. Collision resolution asks "is this key free?" on every
  # request, so it would fail on the very first lookup.
  # Scoped to the bucket itself; the API exposes no listing endpoint.
  statement {
    sid       = "DistinguishMissingKeysFromDenied"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.redirect.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "${var.api_function_name}-policy"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

# Created explicitly so retention is managed; otherwise Lambda makes one that
# never expires.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.api_function_name}"
  retention_in_days = var.api_log_retention_days
}

resource "aws_lambda_function" "api" {
  function_name = var.api_function_name
  role          = aws_iam_role.api.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      BUCKET       = var.redirect_bucket_name
      SHORT_DOMAIN = var.domain_name
      MAX_ATTEMPTS = tostring(var.api_max_attempts)
    }
  }

  depends_on = [
    aws_iam_role_policy.api,
    aws_cloudwatch_log_group.api,
  ]
}

resource "aws_lambda_function_url" "api" {
  function_name = aws_lambda_function.api.function_name

  # Required for CloudFront OAC, and keeps the endpoint closed to anyone who
  # cannot sign a request.
  authorization_type = "AWS_IAM"
}

# OAC signs the origin request with SigV4, which is what AuthType = AWS_IAM
# demands. Note the origin type is "lambda", not "s3".
resource "aws_cloudfront_origin_access_control" "api" {
  name                              = "${var.api_function_name}-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Lets this distribution -- and only this distribution -- invoke the Function
# URL. Direct callers still need their own permissions, which is how
# scripts/call_api.py keeps working.
#
# BOTH statements are required. Function URLs created from October 2025 onward
# check lambda:InvokeFunction as well as lambda:InvokeFunctionUrl, and a
# missing second statement shows up only as a bare 403 from the origin:
#   {"Message": "Forbidden. For troubleshooting Function URL authorization ..."}
# An IAM principal with a wildcard identity policy is unaffected, so signing
# directly can keep working while CloudFront is refused.
resource "aws_lambda_permission" "api_cloudfront_url" {
  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.main.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "api_cloudfront_invoke" {
  statement_id  = "AllowCloudFrontInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.main.arn
}
