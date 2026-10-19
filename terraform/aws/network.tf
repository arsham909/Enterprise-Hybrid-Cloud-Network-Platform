resource "aws_vpc" "main" {
  cidr_block = var.vpc_range

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "forge-vpc"
  }
}
