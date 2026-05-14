# Security group for RDS
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS database"
  vpc_id      = aws_vpc.main.id

  # Allow inbound MySQL/Aurora traffic from the configured CIDR blocks
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.db_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
}

resource "aws_db_subnet_group" "default" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.db_publicly_accessible ? aws_subnet.public[*].id : aws_subnet.private[*].id
  tags = { Name = "${var.project_name}-db-subnet-group" }
}

resource "aws_db_subnet_group" "public" {
  count      = var.db_publicly_accessible ? 1 : 0
  name       = "${var.project_name}-db-subnet-group-public"
  subnet_ids = aws_subnet.public[*].id
  tags = { Name = "${var.project_name}-db-subnet-group-public" }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier      = "${var.project_name}-aurora"
  engine                  = "aurora-mysql"
  database_name           = var.db_name
  master_username         = var.db_username
  master_password         = var.db_password
  db_subnet_group_name    = var.db_publicly_accessible ? aws_db_subnet_group.public[0].name : aws_db_subnet_group.default.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  skip_final_snapshot     = true
  deletion_protection     = false
  storage_encrypted       = true
  tags = { Name = "${var.project_name}-aurora-cluster" }
}

resource "aws_rds_cluster_instance" "aurora_primary" {
  identifier           = "${var.project_name}-aurora-1"
  cluster_identifier   = aws_rds_cluster.aurora.id
  instance_class       = var.db_instance_class
  engine               = aws_rds_cluster.aurora.engine
  db_subnet_group_name = var.db_publicly_accessible ? aws_db_subnet_group.public[0].name : aws_db_subnet_group.default.name
  publicly_accessible  = var.db_publicly_accessible
  tags = { Name = "${var.project_name}-aurora-instance-1" }
}
