output "api_function_url" {
  description = "Function URL for the registration API (requires SigV4)"
  value       = aws_lambda_function_url.api.function_url
}

output "api_function_name" {
  description = "Lambda function name, for logs"
  value       = aws_lambda_function.api.function_name
}

output "admin_url" {
  description = "Admin page (requires signing in)"
  value       = "https://${var.domain_name}/admin"
}

output "oidc_redirect_uri" {
  description = "Register this at the IdP"
  value       = "https://${var.domain_name}${var.callback_path}"
}

output "edge_auth_version_arn" {
  description = "Published Lambda@Edge version wired into CloudFront"
  value       = aws_lambda_function.edge_auth.qualified_arn
}

output "edge_auth_secret_name" {
  description = "Secrets Manager entry to populate (us-east-1)"
  value       = aws_secretsmanager_secret.edge_auth.name
}

output "edge_auth_function_name" {
  description = "Lambda@Edge function name, for diagnostics"
  value       = aws_lambda_function.edge_auth.function_name
}

output "cloudfront_distribution_id" {
  description = "Distribution id, for diagnostics and invalidations"
  value       = aws_cloudfront_distribution.main.id
}
