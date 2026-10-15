# ---------------------------------------------------------------------------
# OIDC authentication at the edge (Lambda@Edge, viewer-request)
#
# Constraints that shape this file:
#   - Must live in us-east-1, whatever region everything else uses.
#   - No environment variables. Config comes from Secrets Manager; the secret
#     name is baked into the bundle at build time (functions/edge-auth).
#   - Viewer-request events cap the package at 1 MB compressed and memory at
#     128 MB, with a 5 second timeout.
#   - Replicas take hours to disappear after being disassociated, so destroy
#     and recreate is slow. Prefer publishing a new version.
#
# Build the bundle before applying:
#   cd functions/edge-auth && npm ci && npm test && npm run build
# ---------------------------------------------------------------------------

data "archive_file" "edge_auth" {
  type        = "zip"
  source_file = "${path.module}/../functions/edge-auth/dist/index.js"
  output_path = "${path.module}/.build/edge-auth.zip"
}

# The container only. The value carries the OIDC client secret and the session
# signing key, so it is written out of band and never enters Terraform state.
# See docs/setup.md.
resource "aws_secretsmanager_secret" "edge_auth" {
  provider = aws.us_east_1

  name        = var.edge_auth_secret_name
  description = "OIDC config for the CloudFront edge authenticator"

  # A stray destroy would take the login flow down and the name is blocked for
  # 7 days afterwards, which makes recreating it awkward.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "edge_auth_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      # edgelambda is what actually runs the replicas; both are required.
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "edge_auth" {
  provider = aws.us_east_1

  name               = "${var.edge_auth_function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.edge_auth_assume_role.json
}

data "aws_iam_policy_document" "edge_auth" {
  statement {
    sid       = "ReadOidcConfig"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.edge_auth.arn]
  }

  # Replicas log into the region nearest the viewer, so the log group cannot be
  # created up front and the resource has to be wildcarded.
  statement {
    sid       = "WriteReplicaLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/*.${var.edge_auth_function_name}:*"]
  }
}

resource "aws_iam_role_policy" "edge_auth" {
  provider = aws.us_east_1

  name   = "${var.edge_auth_function_name}-policy"
  role   = aws_iam_role.edge_auth.id
  policy = data.aws_iam_policy_document.edge_auth.json
}

resource "aws_lambda_function" "edge_auth" {
  provider = aws.us_east_1

  function_name = var.edge_auth_function_name
  role          = aws_iam_role.edge_auth.arn
  handler       = "index.handler"
  runtime       = var.edge_auth_runtime

  # Lambda@Edge does not support arm64.
  architectures = ["x86_64"]

  filename         = data.archive_file.edge_auth.output_path
  source_code_hash = data.archive_file.edge_auth.output_base64sha256

  # Viewer-request ceilings. The IdP round trip happens on the callback only;
  # the common path is a local signature check.
  timeout     = 5
  memory_size = 128

  # CloudFront can only reference a published version, never $LATEST.
  publish = true

  # No environment block: Lambda@Edge rejects environment variables.

  depends_on = [aws_iam_role_policy.edge_auth]
}
