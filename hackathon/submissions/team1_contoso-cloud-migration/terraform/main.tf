terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "contoso-tfstate"
    key    = "cloud-migration/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Networking ────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false # HA — one per AZ

  tags = local.tags
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

# ── ECR Repositories ──────────────────────────────────────────────────────────

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project}-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

# ── RDS (SQL Server → Postgres in cloud) ─────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_db_instance" "reportdb" {
  identifier             = "${var.project}-reportdb"
  engine                 = "postgres"
  engine_version         = "16.1"
  instance_class         = "db.r6g.large"
  allocated_storage      = 500
  max_allocated_storage  = 2000 # auto-scaling storage
  storage_type           = "gp3"
  storage_encrypted      = true

  db_name  = "contoso"
  username = "contoso_admin"
  # password managed via Secrets Manager — see secrets.tf
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = true # HA — matches on-prem SQL Server clustering intent
  backup_retention_period = 7
  deletion_protection    = true
  skip_final_snapshot    = false
  final_snapshot_identifier = "${var.project}-reportdb-final"

  # TODO (ADR-002 gap): linked server to creditcheck.ext.contoso.com must be
  # replaced with application-layer API call before migration. This RDS instance
  # cannot replicate SQL Server linked server functionality. Track in JIRA CLOUD-42.

  tags = local.tags
}

# ── ElastiCache (Redis) ───────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-cache-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "sessions" {
  replication_group_id = "${var.project}-sessions"
  description          = "Session store for Portal — Phase 2 (replaces in-process IIS sessions)"
  node_type            = "cache.t4g.small"
  num_cache_clusters   = 2 # primary + replica
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  tags                 = local.tags
}

# ── S3 (replaces fileserver01 NFS/CIFS) ─────────────────────────────────────

resource "aws_s3_bucket" "recon_inbound" {
  bucket = "${var.project}-recon-inbound-${var.aws_account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "recon_inbound" {
  bucket = aws_s3_bucket.recon_inbound.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "recon_inbound" {
  bucket = aws_s3_bucket.recon_inbound.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket" "finlib_locks" {
  # ADR-002 gap: FinSecLib.dll writes lock files to \\fileserver01\finlib-locks\ (UNC path).
  # This S3 bucket + Mountpoint for S3 replaces the UNC share.
  # Binary compatibility of FinSecLib.dll with Mountpoint must be validated.
  # If validation fails, Windows ECS containers required or tokenisation must be rewritten.
  # Track in JIRA CLOUD-17.
  bucket = "${var.project}-finlib-locks-${var.aws_account_id}"
  tags   = local.tags
}

# ── ALB ──────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets
  tags               = local.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.project}-backend-tg"
  port        = 8001
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

resource "aws_lb_target_group" "frontend" {
  name        = "${var.project}-frontend-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path = "/health"
  }

  tags = local.tags
}

# ── Secrets Manager ──────────────────────────────────────────────────────────

resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.project}/db-password"
  description = "RDS master password — replaces hardcoded DB IPs in web.config and run_recon.py (ADR-002)"
  tags        = local.tags
}

# ── Lambda (S3 event trigger for Recon — Phase 2) ────────────────────────────

resource "aws_lambda_function" "recon_trigger" {
  function_name = "${var.project}-recon-trigger"
  description   = "Triggers Recon ECS task on S3 file arrival — replaces 2am cron (ADR-003 Phase 2)"
  role          = aws_iam_role.lambda_recon.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.backend.repository_url}:recon-trigger-latest"

  environment {
    variables = {
      ECS_CLUSTER      = aws_ecs_cluster.main.name
      ECS_TASK_DEF     = "${var.project}-recon"
      SUBNET_IDS       = join(",", module.vpc.private_subnets)
      SECURITY_GROUP   = aws_security_group.ecs_tasks.id
    }
  }

  tags = local.tags
}

resource "aws_s3_bucket_notification" "recon_trigger" {
  bucket = aws_s3_bucket.recon_inbound.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.recon_trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "inbound/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  ]

  tags = local.tags
}

resource "aws_iam_role" "lambda_recon" {
  name = "${var.project}-lambda-recon"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.tags
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.recon_trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.recon_inbound.arn
}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
