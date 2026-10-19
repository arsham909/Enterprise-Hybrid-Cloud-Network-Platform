variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
  default     = "forge"
}

variable "project_name" {
  description = "Project name, used in tags"
  type        = string
  default     = "forge-hybrid"
}

variable "vpc_range" {
  description = "VPC range"
  type        = string
  default     = "10.50.0.0/16"
}

variable "subnet_range" {
  description = "Public subnet range, inside the VPC range"
  type        = string
  default     = "10.50.0.0/24"
}

variable "managedby" {
  description = "Managed by"
  type        = string
  default     = "terraform"
}
