output "vpc_id" {
  description = "the id of the VPC created"
  value       = aws_vpc.main.id
}
