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

resource "aws_codecommit_repository" "repo" {
  repository_name = var.app_name
  description     = "CodeCommit repo for ${var.app_name}"
}

data "aws_caller_identity" "current" {}

resource "local_file" "buildspec" {
  content = <<EOF
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $REPOSITORY_URI
      - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
  build:
    commands:
      - echo Build started on `date`
      - docker build -t $REPOSITORY_URI:latest .
      - docker tag $REPOSITORY_URI:latest $REPOSITORY_URI:$IMAGE_TAG
  post_build:
    commands:
      - echo Build completed on `date`
      - echo Pushing the Docker image...
      - docker push $REPOSITORY_URI:latest
      - docker push $REPOSITORY_URI:$IMAGE_TAG
      - printf '[{"name":"myapi","imageUri":"%s:%s"}]' "$REPOSITORY_URI" "$IMAGE_TAG" > imagedefinitions.json
artifacts:
  files:
    - imagedefinitions.json
EOF
  filename = "${path.module}/buildspec.yml"
}

resource "null_resource" "push_buildspec" {
  # Re-run if the file content changes
  triggers = {
    buildspec_sha = sha1(local_file.buildspec.content)
    repo_name     = aws_codecommit_repository.repo.repository_name
  }

  provisioner "local-exec" {
    command = <<EOC
set -e
REPO="${aws_codecommit_repository.repo.repository_name}"
BRANCH="master"

# Try to get the latest commit ID; if exists, use as parent, otherwise omit
if COMMIT_ID=$(aws codecommit get-branch \
  --repository-name "$REPO" \
  --branch-name "$BRANCH" \
  --query 'branch.commitId' \
  --output text \
  --region ${var.region} 2>/dev/null); then
  PARENT_ARG="--parent-commit-id $COMMIT_ID"
else
  PARENT_ARG=""
fi

# Push buildspec.yml
aws codecommit put-file \
  --repository-name "$REPO" \
  --branch-name "$BRANCH" \
  --file-path "buildspec.yml" \
  --file-content fileb://buildspec.yml \
  $PARENT_ARG \
  --commit-message "Add buildspec.yml via Terraform" \
  --region ${var.region}
EOC
    interpreter = ["bash", "-c"]
  }

  # Ensure the file is created before attempting to push
  depends_on = [
    local_file.buildspec,
    aws_codecommit_repository.repo
  ]
}

resource "local_file" "dockerfile" {
  content = <<EOF
FROM python:3.8-slim

# Set working directory
WORKDIR /app

# Install Streamlit
RUN pip install --no-cache-dir streamlit

# Copy the application code into the container
COPY app.py .

# Expose the Streamlit default port
EXPOSE 8501

# Run Streamlit when the container launches
CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF
  filename = "${path.module}/Dockerfile"
}

resource "local_file" "app_py" {
  content = <<EOF
import streamlit as st

st.title("Hello, world!")
st.write("This is a Streamlit hello world app.")
EOF
  filename = "${path.module}/app.py"
}

resource "null_resource" "push_dockerfile" {
  triggers = {
    dockerfile_sha = sha1(local_file.dockerfile.content)
    app_py_sha     = sha1(local_file.app_py.content)
    repo_name      = aws_codecommit_repository.repo.repository_name
  }

  provisioner "local-exec" {
    command = <<EOC
set -e
REPO="${aws_codecommit_repository.repo.repository_name}"
BRANCH="master"

# Helper function to push a file, handling initial commit
push_file() {
  local FILE_PATH="$1"
  local COMMIT_MSG="$2"

  if PARENT=$(aws codecommit get-branch \
    --repository-name "$REPO" \
    --branch-name "$BRANCH" \
    --query 'branch.commitId' \
    --output text \
    --region ${var.region} 2>/dev/null); then
    PARENT_ARG="--parent-commit-id $PARENT"
  else
    PARENT_ARG=""
  fi

  aws codecommit put-file \
    --repository-name "$REPO" \
    --branch-name "$BRANCH" \
    --file-path "$FILE_PATH" \
    --file-content fileb://"$FILE_PATH" \
    $PARENT_ARG \
    --commit-message "$COMMIT_MSG" \
    --region ${var.region}
}

# Push Dockerfile
push_file "Dockerfile" "Add Dockerfile via Terraform"

# Push app.py
push_file "app.py" "Add Streamlit hello world app via Terraform"
EOC
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    local_file.dockerfile,
    local_file.app_py,
    aws_codecommit_repository.repo
  ]
}

# ------------------------
# ECR Repository
# ------------------------
resource "aws_ecr_repository" "repo" {
  name = var.app_name
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "repo_policy" {
  repository = aws_ecr_repository.repo.name

  policy = <<EOF
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire images older than the most recent one",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 1
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
EOF
}

# ------------------------
# IAM Role for CodeBuild
# ------------------------
resource "aws_iam_role" "codebuild_role" {
  name = "${var.app_name}-codebuild-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "codebuild_ecr_power_user" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_role_policy_attachment" "codebuild_developer_access" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess"
}

resource "aws_iam_role_policy_attachment" "codebuild_cloudwatch_logs_full_access" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "codebuild_s3_read_access" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "codebuild_s3_full_access" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# ------------------------
# CodeBuild Project
# ------------------------
resource "aws_codebuild_project" "codebuild" {
  name          = "${var.app_name}-codebuild"
  description   = "Build project to build Docker image and push to ECR"
  service_role  = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_LARGE"
    image                       = "aws/codebuild/standard:5.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.repo.repository_url
      type  = "PLAINTEXT"
    }
  }

  source {
    type      = "CODECOMMIT"
    location  = aws_codecommit_repository.repo.clone_url_http
    buildspec = "buildspec.yml"
  }
}

# ------------------------
# S3 Bucket for CodePipeline Artifacts
# ------------------------
resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = "${var.app_name}-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "codepipeline_bucket_versioning" {
  bucket = aws_s3_bucket.codepipeline_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ------------------------
# IAM Role for CodePipeline
# ------------------------
resource "aws_iam_role" "codepipeline_role" {
  name = "${var.app_name}-codepipeline-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}


resource "aws_iam_role_policy_attachment" "codepipeline_full_access" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodePipeline_FullAccess"
}

resource "aws_iam_role_policy_attachment" "codepipeline_codecommit_read" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeCommitReadOnly"
}

resource "aws_iam_role_policy_attachment" "codepipeline_codecommit_poweruser" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeCommitPowerUser"
}

resource "aws_iam_role_policy" "codepipeline_codecommit_inline" {
  name = "${var.app_name}-codepipeline-cc-inline"
  role = aws_iam_role.codepipeline_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:UploadArchive"
      ],
      "Resource": "${aws_codecommit_repository.repo.arn}"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_s3_access" {
  name = "${var.app_name}-codepipeline-s3-inline"
  role = aws_iam_role.codepipeline_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:ListBucket"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "codepipeline_codebuild_full_access" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeBuildAdminAccess"
}

resource "aws_iam_role_policy_attachment" "codepipeline_ecr_full_access" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_role_policy_attachment" "codepipeline_ecs_full_access" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

# ------------------------
# CodePipeline Definition
# ------------------------
resource "aws_codepipeline" "pipeline" {
  name     = "${var.app_name}-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"
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
        BranchName     = "master"
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
        ProjectName = aws_codebuild_project.codebuild.name
      }
    }
  }
}

# Automatically start the pipeline after creation
resource "null_resource" "start_pipeline" {
  # Trigger whenever the pipeline name changes (i.e., on creation)
  triggers = {
    pipeline_name = aws_codepipeline.pipeline.name
  }

  provisioner "local-exec" {
    command     = "aws codepipeline start-pipeline-execution --name ${aws_codepipeline.pipeline.name} --region ${var.region}"
    interpreter = ["bash", "-c"]
  }

  depends_on = [
    aws_codepipeline.pipeline
  ]
}

# ------------------------
# VPC and Networking
# ------------------------
resource "aws_vpc" "ecs_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "${var.app_name}-vpc"
  }
}

resource "aws_subnet" "ecs_public_subnet" {
  vpc_id                  = aws_vpc.ecs_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"
  tags = {
    Name = "${var.app_name}-public-subnet"
  }
}

resource "aws_internet_gateway" "ecs_igw" {
  vpc_id = aws_vpc.ecs_vpc.id
  tags = {
    Name = "${var.app_name}-igw"
  }
}

resource "aws_route_table" "ecs_public_rt" {
  vpc_id = aws_vpc.ecs_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ecs_igw.id
  }
  tags = {
    Name = "${var.app_name}-public-rt"
  }
}

resource "aws_route_table_association" "ecs_public_rta" {
  subnet_id      = aws_subnet.ecs_public_subnet.id
  route_table_id = aws_route_table.ecs_public_rt.id
}

# ------------------------
# Security Group for ECS
# ------------------------
resource "aws_security_group" "ecs_sg" {
  name        = "${var.app_name}-ecs-sg"
  description = "Allow HTTP and Streamlit ports"
  vpc_id      = aws_vpc.ecs_vpc.id

  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    description      = "Streamlit"
    from_port        = 8501
    to_port          = 8501
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-ecs-sg"
  }
}

# ------------------------
# ECS Cluster
# ------------------------
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.app_name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = {
    Name = "${var.app_name}-cluster"
  }
}

# ------------------------
# IAM Role for ECS Task Execution
# ------------------------
resource "aws_iam_role" "ecs_task_exec_role" {
  name = "${var.app_name}-ecs-exec-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_policy" {
  role       = aws_iam_role.ecs_task_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ------------------------
# ECS Task Definition
# ------------------------
resource "aws_ecs_task_definition" "task" {
  family                   = "${var.app_name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_exec_role.arn

  container_definitions = jsonencode([
    {
      name      = "${var.app_name}-container"
      image     = "${aws_ecr_repository.repo.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8501
          hostPort      = 8501
          protocol      = "tcp"
        }
      ]
    }
  ])
}

# ------------------------
# ECS Service
# ------------------------
resource "aws_ecs_service" "ecs_service" {
  name            = "${var.app_name}-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.ecs_public_subnet.id]
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_exec_policy
  ]
}
