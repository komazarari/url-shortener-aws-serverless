locals {
  redirect_origin_id = "${var.redirect_bucket_name}.s3-website-${var.aws_region}.amazonaws.com"
  admin_origin_id    = "admin-${var.admin_bucket_name}"
  api_origin_id      = "api-${var.api_function_name}"

  # https://xxxx.lambda-url.<region>.on.aws/ -> xxxx.lambda-url.<region>.on.aws
  api_origin_domain = trimsuffix(
    trimprefix(aws_lambda_function_url.api.function_url, "https://"),
    "/",
  )
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header except Host. Needed so x-amz-content-sha256
# reaches the origin: Lambda rejects unsigned payloads, so OAC has to include
# the caller's body hash in the signature.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "main" {
  aliases         = [var.domain_name]
  enabled         = true
  http_version    = "http2"
  is_ipv6_enabled = true
  price_class     = "PriceClass_200"

  retain_on_delete    = false
  staging             = false
  wait_for_deployment = true

  origin {
    domain_name         = local.redirect_origin_id
    origin_id           = local.redirect_origin_id
    connection_attempts = 3
    connection_timeout  = 10

    response_completion_timeout = 0

    custom_origin_config {
      http_port  = 80
      https_port = 443

      # for website endpoint (not supported HTTPS)
      origin_protocol_policy = "http-only"

      origin_ssl_protocols = ["SSLv3", "TLSv1", "TLSv1.1", "TLSv1.2"]

      origin_keepalive_timeout = 5
      origin_read_timeout      = 30
    }

    # Allow access only from CloudFront. Must be Referer (or User-Agent):
    # they are the only HTTP headers with an IAM condition key.
    # CloudFront overwrites any Referer sent by the viewer, so it cannot be forged.
    custom_header {
      name  = "Referer"
      value = var.origin_secret
    }
  }

  origin {
    domain_name              = aws_s3_bucket.admin.bucket_regional_domain_name
    origin_id                = local.admin_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.admin.id
  }

  origin {
    domain_name              = local.api_origin_domain
    origin_id                = local.api_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.api.id

    # A Function URL is a custom origin, not an S3 one.
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # --- Authenticated behaviours -------------------------------------------
  #
  # Deliberately ordered before the default. The default behaviour stays free
  # of edge functions so redirects keep working even if auth breaks.

  # The edge function answers this itself; the origin is never reached, but a
  # behaviour still needs one.
  ordered_cache_behavior {
    path_pattern     = var.callback_path
    target_origin_id = local.admin_origin_id

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"
    # Every callback carries a one-time code; nothing here is cacheable.
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_disabled.id

    lambda_function_association {
      event_type = "viewer-request"
      lambda_arn = aws_lambda_function.edge_auth.qualified_arn
      # No request body is needed to validate the callback query string.
      include_body = false
    }
  }

  ordered_cache_behavior {
    path_pattern     = "/admin*"
    target_origin_id = local.admin_origin_id

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    # The page is tiny and must never be served to the wrong session.
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_disabled.id

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.edge_auth.qualified_arn
      include_body = false
    }
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = local.api_origin_id

    # The only behaviour that accepts writes. The default one stays GET/HEAD.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    lambda_function_association {
      event_type = "viewer-request"
      lambda_arn = aws_lambda_function.edge_auth.qualified_arn

      # Must stay false. The viewer's x-amz-content-sha256 covers the body it
      # sent; if the edge function received and re-emitted the body, the hash
      # would no longer match what OAC signs and the origin would reject it.
      include_body = false
    }
  }

  default_cache_behavior {
    target_origin_id = local.redirect_origin_id

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # Managed-CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    min_ttl         = 0
    default_ttl     = 0
    max_ttl         = 0

    smooth_streaming   = false
    trusted_key_groups = []
    trusted_signers    = []

    grpc_config {
      enabled = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.acm_certificate_arn
    cloudfront_default_certificate = false
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = "sni-only"
  }

  # 【TODO】Enable access log
  # logging_config {
  #   bucket = "<log-bucket>.s3.amazonaws.com"
  #   prefix = "cloudfront/"
  # }
}
