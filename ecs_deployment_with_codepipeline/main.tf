terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

#--------------------------------------
# Variables
#--------------------------------------
variable "region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-southeast-3"
}

variable "app_name" {
  description = "Name of the application and prefix for resources"
  type        = string
  default     = "myapi"
}

variable "vpc_cidr" {
  description = "CIDR block for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

#--------------------------------------
# Networking: VPC, Subnets, Internet Gateway, Route Tables
#--------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.app_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.app_name}-igw"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  for_each                = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = data.aws_availability_zones.available.names[each.key]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.app_name}-public-${each.key}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.app_name}-public-rt"
  }
}

resource "aws_route" "default_public_route" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_association" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private" {
  for_each                = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = data.aws_availability_zones.available.names[each.key]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.app_name}-private-${each.key}"
  }
}

resource "aws_eip" "nat_eip" {
  vpc        = true
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.app_name}-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.app_name}-private-rt"
  }
}

resource "aws_route" "private_route" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_association" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

#--------------------------------------
# ECR Repository
#--------------------------------------
resource "aws_ecr_repository" "app" {
  name = var.app_name
}

#--------------------------------------
# IAM Roles and Policies
#--------------------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name_prefix         = "${var.app_name}-ecs-task-exec-role-"
  assume_role_policy  = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Principal = { Service = "ecs-tasks.amazonaws.com" },
        Effect    = "Allow"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "codebuild_role" {
  name_prefix         = "${var.app_name}-codebuild-role-"
  assume_role_policy  = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Principal = { Service = "codebuild.amazonaws.com" },
        Effect    = "Allow"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_ecr_access" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "codebuild_ecs_update" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

resource "aws_iam_role" "codepipeline_role" {
  name_prefix         = "${var.app_name}-codepipeline-role-"
  assume_role_policy  = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Principal = { Service = "codepipeline.amazonaws.com" },
        Effect    = "Allow"
      }
    ]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name   = "${var.app_name}-codepipeline-policy"
  role   = aws_iam_role.codepipeline_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:UploadArchive",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:CancelUploadArchive"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "iam:PassRole"
        ],
        Resource = [
          aws_iam_role.ecs_task_execution_role.arn,
          aws_iam_role.codebuild_role.arn
        ]
      },
      {
        Effect   = "Allow",
        Action   = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = "*"
      }
    ]
  })
}

#--------------------------------------
# Security Groups and ALB
#--------------------------------------
resource "aws_security_group" "alb_sg" {
  name        = "${var.app_name}-alb-sg"
  description = "Allow HTTP inbound"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = "${var.app_name}-ecs-sg"
  description = "Allow traffic from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "alb" {
  name               = "${var.app_name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = values(aws_subnet.public)[*].id
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.app_name}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

#--------------------------------------
# ECS Cluster, Task Definition, Service
#--------------------------------------
resource "aws_ecs_cluster" "cluster" {
  name = "${var.app_name}-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = var.app_name
      image     = "${aws_ecr_repository.app.repository_url}:latest"
      portMappings = [
        { containerPort = 80, hostPort = 80, protocol = "tcp" }
      ]
      essential = true
    }
  ])
}

resource "aws_ecs_service" "service" {
  name            = "${var.app_name}-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = values(aws_subnet.private)[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = var.app_name
    container_port   = 80
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener.listener]
}

#--------------------------------------
# CodeCommit Repository (Source)
#--------------------------------------
resource "aws_codecommit_repository" "repo" {
  repository_name = var.app_name
  description     = "CodeCommit repo for ${var.app_name}"
}

#--------------------------------------
# S3 Bucket for Pipeline Artifacts
#--------------------------------------
resource "aws_s3_bucket" "artifact_store" {
  bucket        = "${var.app_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.app_name}-artifacts"
  }
}

#--------------------------------------
# CodeBuild Project (Build & Push Docker Image)
#--------------------------------------
resource "aws_codebuild_project" "build" {
  name         = "${var.app_name}-build"
  service_role = aws_iam_role.codebuild_role.arn
  description  = "Build Docker image and push to ECR"

  artifacts {
    type      = "CODEPIPELINE"
    packaging = "NONE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "APP_NAME"
      value = var.app_name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = <<EOF
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $REPOSITORY_URI
  build:
    commands:
      - echo Build started on `date`
      - echo Building the Docker image...
      - docker build -t $REPOSITORY_URI:latest .
      - docker push $REPOSITORY_URI:latest
  post_build:
    commands:
      - printf '[{"name":"%s","imageUri":"%s:latest"}]' "$APP_NAME" "$REPOSITORY_URI" > imagedefinitions.json
artifacts:
  files: imagedefinitions.json
EOF
  }
}

#--------------------------------------
# CodePipeline
#--------------------------------------
resource "aws_codepipeline" "pipeline" {
  name     = "${var.app_name}-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifact_store.bucket
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName = aws_codecommit_repository.repo.repository_name
        BranchName     = "main"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "DeployToECS"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "ECS"
      input_artifacts  = ["build_output"]
      version          = "1"

      configuration = {
        ClusterName = aws_ecs_cluster.cluster.name
        ServiceName = aws_ecs_service.service.name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}

#--------------------------------------
# Seed CodeCommit by generating README.md and pushing via AWS credential helper
#--------------------------------------
resource "null_resource" "push_initial_repo_contents" {
  triggers = {
    repo_clone_url = aws_codecommit_repository.repo.clone_url_http
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -e

      TMP_DIR="$(mktemp -d -t ${var.app_name}-git-XXXXXX)"
      echo "→ Initializing local Git repo in $TMP_DIR …"

      cd "$TMP_DIR"
      git init
      git checkout -b main

      cat > README.md <<__EOF__
# ${var.app_name}

This is the initial README for the '${var.app_name}' CodeCommit repository.
__EOF__

      if ! git config user.name > /dev/null; then
        git config user.name "terraform-codecommit-bot"
      fi
      if ! git config user.email > /dev/null; then
        git config user.email "terraform@localhost"
      fi

      git add README.md
      git commit -m "Initial commit from Terraform"

      git remote add origin "${aws_codecommit_repository.repo.clone_url_http}"
      git config credential.helper '!aws codecommit credential-helper $@'
      git config credential.UseHttpPath true

      echo "→ Pushing initial commit to CodeCommit (no Git user/password prompt) …"
      git push -u origin main

      cd /
      rm -rf "$TMP_DIR"
      echo "✅ Successfully pushed initial README.md to CodeCommit."
    EOT
  }

  depends_on = [
    aws_codecommit_repository.repo
  ]
}

#--------------------------------------
# Data Sources
#--------------------------------------
data "aws_caller_identity" "current" {}
