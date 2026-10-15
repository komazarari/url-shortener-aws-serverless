# ---------------------------------------------------------------------------
#
# Prerequisite: Enter the bucket name for storing the terraform state in `backend.hcl`,
# to init:
#
#   terraform init -backend-config=backend.hcl
#
# ---------------------------------------------------------------------------

terraform {
  backend "s3" {}
}
