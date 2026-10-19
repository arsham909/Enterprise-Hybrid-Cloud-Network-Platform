provider "aws" {
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = var.managedby
    }
  }
  region  = var.aws_region
  profile = var.aws_profile
}
