variable "aws_region" {
  description = "Main region. CloudFront-adjacent resources go to us-east-1 regardless."
  type        = string
  default     = "ap-northeast-1"
}

variable "domain_name" {
  description = "Domain serving the short links, e.g. short.example.net"
  type        = string
}

variable "redirect_bucket_name" {
  description = <<-EOT
    Bucket holding the redirect objects.

    Must be globally unique: it becomes an S3 website endpoint hostname, and
    that endpoint is the only thing that turns the redirect metadata into a 301.
  EOT
  type        = string
}

# DNS is out of scope. Point a CNAME at the distribution yourself.

# ---------------------------------------------------------------------------
# Origin lock
# ---------------------------------------------------------------------------

variable "origin_secret" {
  description = <<-EOT
    Secret CloudFront puts in the Referer header, paired with the aws:Referer
    condition on the bucket policy to stop people reaching the S3 website
    endpoint directly.

    Generate with: openssl rand -hex 32

    Never exposed to browsers, but note this is obfuscation rather than a
    security boundary -- see docs/design.md section 3.2.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.origin_secret) >= 32
    error_message = "origin_secret must be at least 32 characters (openssl rand -hex 32)."
  }
}

# ---------------------------------------------------------------------------
# Edge authentication
# ---------------------------------------------------------------------------

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of an ISSUED ACM certificate covering domain_name.

    Must live in us-east-1: CloudFront only accepts certificates from there.
    Taken as input rather than created here so the setup does not depend on
    where your DNS is hosted -- issuing a certificate requires DNS validation,
    and that varies per provider.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.acm_certificate_arn))
    error_message = "Must be an ACM certificate ARN in us-east-1."
  }
}

variable "edge_auth_function_name" {
  description = "Lambda@Edge function name (us-east-1)"
  type        = string
  default     = "url-shortener-edge-auth"
}

variable "edge_auth_secret_name" {
  description = <<-EOT
    Secrets Manager secret holding the OIDC config.
    Must match SM_CONFIG_KEY.json in functions/edge-auth, which is baked into
    the bundle at build time.
  EOT
  type        = string
  default     = "url-shortener/edge-auth-config"
}

variable "edge_auth_runtime" {
  description = <<-EOT
    Node runtime for the edge function.

    Lambda@Edge historically lags plain Lambda by a release or two, and an
    unsupported runtime surfaces as a 503 with no logs rather than a clear
    error. Drop to nodejs20.x if that happens.
  EOT
  type        = string
  default     = "nodejs22.x"
}

variable "callback_path" {
  description = "OIDC redirect URI path. Must match CALLBACK_PATH in the secret."
  type        = string
  default     = "/_callback"
}

variable "admin_bucket_name" {
  description = <<-EOT
    Name prefix for the admin page bucket. The account id and region are
    appended and the bucket uses the account-regional namespace, so this does
    not need to be globally unique. Kept private behind OAC.
  EOT
  type        = string
}

variable "api_function_name" {
  description = "Lambda function name for the registration API"
  type        = string
  default     = "url-shortener-api"
}

variable "api_log_retention_days" {
  description = "CloudWatch Logs retention for the API Lambda"
  type        = number
  default     = 30
}

variable "api_max_attempts" {
  description = "Collision retry limit when deriving a key"
  type        = number
  default     = 16
}

variable "enforce_origin_secret" {
  description = <<-EOT
    Whether the bucket policy requires the Referer secret.

    Leave this true for a fresh install: both sides appear in the same apply,
    so there is no window to manage.

    The flag exists for retrofitting a running service, where the order
    matters. S3 policies apply instantly while CloudFront takes minutes, so:
      false -> CloudFront starts sending the header; policy still open
      (wait for the distribution to report Deployed)
      true  -> policy starts requiring it

    Doing that in reverse takes redirects down until propagation finishes.
    Rolling back is just true -> false and apply.
  EOT
  type        = bool
  default     = false
}
