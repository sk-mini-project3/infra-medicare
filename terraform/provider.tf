provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    # backend config cannot use variables.
    # Set these via -backend-config flags or terraform init:
    # terraform init -backend-config="bucket=YOUR_BUCKET" -backend-config="region=ap-northeast-2" ...
    # Or hardcode values below:
    # bucket = "your-tf-state-bucket-name"
    # key    = "medical-service/terraform.tfstate"
    # region = "ap-northeast-2"
    # dynamodb_table = "terraform-locks"
    # encrypt = true
  }
}
