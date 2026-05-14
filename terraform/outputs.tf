output "ecr_frontend_repository" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "ECR frontend repository URL"
}

output "ecr_backend_repository" {
  value       = aws_ecr_repository.backend.repository_url
  description = "ECR backend repository URL"
}

output "ecr_ai_repository" {
  value       = aws_ecr_repository.ai.repository_url
  description = "ECR AI repository URL"
}

output "eks_cluster_name" {
  value       = aws_eks_cluster.eks.name
  description = "EKS cluster name"
}

output "eks_cluster_endpoint" {
  value       = aws_eks_cluster.eks.endpoint
  description = "EKS cluster API endpoint"
}

output "rds_endpoint" {
  value       = "${aws_rds_cluster.aurora.endpoint}:3306"
  description = "Aurora MySQL endpoint (host:port)"
  sensitive   = true
}

output "rds_address" {
  value       = aws_rds_cluster.aurora.endpoint
  description = "Aurora MySQL writer endpoint hostname"
  sensitive   = true
}

output "db_name" {
  value       = var.db_name
  description = "Database name"
}

output "terraform_state_bucket" {
  value       = "Manually configured during 'terraform init -backend-config'"
  description = "S3 bucket for Terraform state (set during backend config)"
}
