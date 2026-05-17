terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State is stored per-workspace automatically.
  # Init once with:
  #   terraform init \
  #     -backend-config="bucket=<YOUR_BUCKET>" \
  #     -backend-config="region=us-east-1" \
  #     -backend-config="dynamodb_table=<YOUR_LOCK_TABLE>" \
  #     -backend-config="encrypt=true"
  #
  # The key uses the workspace name so each env gets its own state file.
  backend "s3" {
    key = "terraform.tfstate"
    # bucket, region, dynamodb_table passed via -backend-config on init
    # Workspace prefix is automatic: env:/<workspace>/terraform.tfstate
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = terraform.workspace
      ManagedBy   = "terraform"
    }
  }
}
