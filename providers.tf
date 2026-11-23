# -----------------------------------------------------------------------------
# providers.tf
# Configures Terraform, the AWS provider, and the deployment region.
# The region defaults to US East (Ohio), us-east-2, the closest AWS region
# to the school's location in Ann Arbor, Michigan.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every resource created by this project receives these tags, which makes
  # cost tracking and inventory easier for a small IT team.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
