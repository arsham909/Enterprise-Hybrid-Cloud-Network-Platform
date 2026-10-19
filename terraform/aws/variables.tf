variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"

}

variable "aws_profile" {
  description = "AWS profile"
  type        = string
  default     = "forge"

}

variable "project_name" {
  description = "project name"
  type        = string
  default     = "forge-hybrid"

}

variable "VPC_range" {
  description = "VPC range"
  type        = string
  default     = "10.0.0.0/16"
}

variable "cidr_block" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.50.0.0/24"
}

variable "managedby" {
  description = "Managed by"
  type        = string
  default     = "terraform"
}
