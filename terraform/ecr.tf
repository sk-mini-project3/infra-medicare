resource "aws_ecr_repository" "frontend" {
  name                 = var.ecr_frontend_name
  image_tag_mutability = "MUTABLE"
  tags = { Name = var.ecr_frontend_name }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "backend" {
  name                 = var.ecr_backend_name
  image_tag_mutability = "MUTABLE"
  tags = { Name = var.ecr_backend_name }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "ai" {
  name                 = var.ecr_ai_name
  image_tag_mutability = "MUTABLE"
  tags = { Name = var.ecr_ai_name }

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ECR Lifecycle Policies
resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 1 untagged image for 7 days"
        selection = {
          tagStatus     = "untagged"
          countType     = "imageSinceImagePushed"
          countUnit     = "days"
          countNumber   = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 1 untagged image for 7 days"
        selection = {
          tagStatus     = "untagged"
          countType     = "imageSinceImagePushed"
          countUnit     = "days"
          countNumber   = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "ai" {
  repository = aws_ecr_repository.ai.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 1 untagged image for 7 days"
        selection = {
          tagStatus     = "untagged"
          countType     = "imageSinceImagePushed"
          countUnit     = "days"
          countNumber   = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}
