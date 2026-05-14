variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

# Note: terraform_state_bucket is passed to 'terraform init -backend-config' flag,
# not as a variable. Uncomment below only if you want to reference it elsewhere.
# variable "terraform_state_bucket" {
#   type = string
# }

variable "project_name" {
  type    = string
  default = "medical-service"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_name" {
  type    = string
  default = "medicalservicedb"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9]*$", var.db_name))
    error_message = "db_name must start with a letter and contain only alphanumeric characters."
  }
}

variable "db_password" {
  type      = string
  description = "Set this via terraform.tfvars or environment (sensitive)"
  sensitive = true
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "db_publicly_accessible" {
  type        = bool
  default     = false
  description = "Whether the Aurora writer instance should be publicly reachable"
}

variable "db_allowed_cidrs" {
  type        = list(string)
  default     = ["10.0.0.0/16"]
  description = "CIDR blocks allowed to reach the Aurora MySQL port"
}

variable "eks_cluster_version" {
  type    = string
  default = "1.27"
}

variable "eks_node_group_size" {
  type    = number
  default = 2
}

variable "ecr_frontend_name" {
  type    = string
  default = "medical-service-frontend"
}

variable "ecr_backend_name" {
  type    = string
  default = "medical-service-backend"
}

variable "ecr_ai_name" {
  type    = string
  default = "medical-service-ai"
}
