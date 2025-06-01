terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "local" {}

# Ensure local directory exists
resource "null_resource" "create_repo_folder" {
  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/my-repo-contents/app"
  }
}

variable "greeting_text" {
  type        = string
  default     = "Hello!"
  description = "The greeting text to display in hello.html"
}

# Create hello.html in the local folder "my-repo-contents"
resource "local_file" "hello_page" {
  depends_on = [null_resource.create_repo_folder]
  filename   = "${path.module}/my-repo-contents/hello.html"
  content    = <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Hello World</title>
</head>
<body>
  <h1>${var.greeting_text}</h1>
  <p>This file was pushed to CodeCommit via Terraform.</p>
</body>
</html>
EOF
}

# Create buildspec.yml in the same local folder
resource "local_file" "buildspec" {
  depends_on = [null_resource.create_repo_folder]
  filename   = "${path.module}/my-repo-contents/buildspec.yml"
  content    = <<EOF
version: 0.2

phases:
  install:
    runtime-versions:
      python: 3.8
    commands:
      - pip install pytest
  build:
    commands:
      - pytest --junitxml=reports/junit.xml

reports:
  pytest-report:
    files:
      - reports/junit.xml
    base-directory: reports
EOF
}

# Create a sample Python application
resource "local_file" "app_main" {
  depends_on = [null_resource.create_repo_folder]
  filename   = "${path.module}/my-repo-contents/app/main.py"
  content    = <<EOF
def add(a, b):
    return a + b

if __name__ == "__main__":
    print("Add 2 + 3 =", add(2, 3))
EOF
}

# Create a pytest unit test for the application
resource "local_file" "app_test" {
  depends_on = [null_resource.create_repo_folder]
  filename   = "${path.module}/my-repo-contents/app/test_main.py"
  content    = <<EOF
import pytest
from main import add

def test_add_positive():
    assert add(2, 3) == 5

def test_add_negative():
    assert add(-1, -1) == -2
EOF
}

# Configure AWS provider for Jakarta region
provider "aws" {
  region = "ap-southeast-3"
}

# Create (or reference) a CodeCommit repository named "my-repo"
resource "aws_codecommit_repository" "my_repo" {
  repository_name = "my-repo"
  description     = "Repository for my application code."
}

# Combine checksums of hello.html and buildspec.yml so re-run triggers when either changes
locals {
  combined_sha = sha256("${local_file.hello_page.content}${local_file.buildspec.content}${local_file.app_main.content}${local_file.app_test.content}")
}

# Push hello.html and buildspec.yml into CodeCommit via AWS CLI
resource "null_resource" "push_files" {
  depends_on = [
    null_resource.create_repo_folder,
    local_file.hello_page,
    local_file.buildspec,
    local_file.app_main,
    local_file.app_test
  ]
  # Re-run when either file content changes, or always (due to timestamp)
  triggers = {
    combined_sha = local.combined_sha
    always_run   = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOF
set -e
REPO_NAME="${aws_codecommit_repository.my_repo.repository_name}"
BRANCH="main"

# Check if the branch exists
BRANCH_EXISTS=$(aws codecommit get-branch --repository-name "$REPO_NAME" --branch-name "$BRANCH" --query 'branch.branchName' --output text 2>/dev/null || echo "")

# Function to push a single file to CodeCommit
push_file() {
  local FILE_PATH=$1
  local LOCAL_FILE=$2

  if [ "$BRANCH_EXISTS" = "$BRANCH" ]; then
    PARENT_COMMIT=$(aws codecommit get-branch --repository-name "$REPO_NAME" --branch-name "$BRANCH" --query 'branch.commitId' --output text)
    aws codecommit put-file \
      --repository-name "$REPO_NAME" \
      --branch-name "$BRANCH" \
      --file-path "$FILE_PATH" \
      --file-content fileb://"$LOCAL_FILE" \
      --parent-commit-id "$PARENT_COMMIT" \
      --commit-message "Update $FILE_PATH" \
      --region ap-southeast-3 \
    || true
  else
    aws codecommit put-file \
      --repository-name "$REPO_NAME" \
      --branch-name "$BRANCH" \
      --file-path "$FILE_PATH" \
      --file-content fileb://"$LOCAL_FILE" \
      --commit-message "Add $FILE_PATH" \
      --region ap-southeast-3 \
    || true
  fi
}

# Push hello.html
push_file "hello.html" "${path.module}/my-repo-contents/hello.html"

# Push buildspec.yml
push_file "buildspec.yml" "${path.module}/my-repo-contents/buildspec.yml"

# Push application code and tests
push_file "app/main.py" "${path.module}/my-repo-contents/app/main.py"
push_file "app/test_main.py" "${path.module}/my-repo-contents/app/test_main.py"
EOF
  }
}

# Generate a random suffix for the CodePipeline artifact bucket
resource "random_id" "pipeline_artifact_id" {
  byte_length = 4
}

# Create an S3 bucket for CodePipeline artifacts
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "pipeline-artifacts-${random_id.pipeline_artifact_id.hex}"
  force_destroy = true

  tags = {
    Name = "PipelineArtifacts"
  }
}

# IAM role for CodePipeline
data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name               = "codepipeline-role-${random_id.pipeline_artifact_id.hex}"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

# Attach a policy to allow CodePipeline to interact with CodeCommit, CodeBuild, and S3 (artifact bucket)
resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codecommit:GetBranch",
          "codecommit:GetCommit",
          "codecommit:GitPull",
          "codecommit:UploadArchive",
          "codecommit:GetUploadArchiveStatus",
          "codecommit:GetFile",
          "codecommit:GetFolder"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ]
        Resource = ["${aws_codebuild_project.hello_build.arn}"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts.arn
        ]
      }
    ]
  })
}

# IAM role for CodeBuild
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codebuild_role" {
  name               = "codebuild-service-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

# Policy for CodeBuild: allow CloudWatch logs, CodeCommit read, and S3 read
resource "aws_iam_role_policy" "codebuild_policy" {
  name = "codebuild-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["codebuild:*"]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:*",
          "cloudwatch:*"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# CodeBuild project that simply echoes "Hello, CodeBuild!"
resource "aws_codebuild_project" "hello_build" {
  name        = "hello-codebuild-project"
  description = "Simple CodeBuild project to echo a hello message"

  source {
    type      = "CODECOMMIT"
    location  = aws_codecommit_repository.my_repo.clone_url_http
    buildspec = "buildspec.yml"
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_LARGE"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"
    environment_variable {
      name  = "GREETING_TEXT"
      value = var.greeting_text
    }
  }

  service_role = aws_iam_role.codebuild_role.arn
}

# CodePipeline: Source (CodeCommit) → Build (CodeBuild)
resource "aws_codepipeline" "build_pipeline" {
  name     = "build-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
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
        RepositoryName = aws_codecommit_repository.my_repo.repository_name
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
      version          = "1"
      input_artifacts  = ["source_output"]
      configuration = {
        ProjectName = aws_codebuild_project.hello_build.name
      }
    }
  }
}

# Always execute the CodePipeline after apply
resource "null_resource" "execute_pipeline" {
  # Ensures this runs on every apply
  triggers = {
    always = timestamp()
  }

  provisioner "local-exec" {
    command = "aws codepipeline start-pipeline-execution --name ${aws_codepipeline.build_pipeline.name} --region ap-southeast-3"
  }

  depends_on = [
    aws_codepipeline.build_pipeline
  ]
}