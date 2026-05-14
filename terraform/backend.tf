# Terraform Backend Configuration (S3 + DynamoDB)
# 
# Backend config is defined in provider.tf as a static block.
# Since Terraform backend blocks cannot use variables, use -backend-config flags during init:
#
# Example:
# terraform init \
#   -backend-config="bucket=mini3-tfstate-prod" \
#   -backend-config="key=medical-service/terraform.tfstate" \
#   -backend-config="region=ap-northeast-2" \
#   -backend-config="dynamodb_table=terraform-locks" \
#   -backend-config="encrypt=true"
#
# Prerequisites (run these BEFORE terraform init):
# 1. Create S3 bucket:
#    aws s3 mb s3://mini3-tfstate-prod --region ap-northeast-2
#
# 2. Create DynamoDB lock table:
#    aws dynamodb create-table \
#      --table-name terraform-locks \
#      --attribute-definitions AttributeName=LockID,AttributeType=S \
#      --key-schema AttributeName=LockID,KeyType=HASH \
#      --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
#      --region ap-northeast-2
#
# 3. Then run terraform init with -backend-config flags (see example above)
