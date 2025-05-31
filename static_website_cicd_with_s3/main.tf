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

variable "greeting_text" {
  type        = string
  default     = "Hello!"
  description = "The greeting text to display in hello.html"
}

# Ensure the "my-repo-contents" directory exists and create "hello.html"
resource "local_file" "hello_page" {
  filename = "${path.module}/my-repo-contents/hello.html"
  content  = <<EOF
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


##############################################################################
# main.tf: Push local folder "my-repo-contents" into a CodeCommit repository #
##############################################################################

# 1. Configure AWS provider for Jakarta region
provider "aws" {
  region = "ap-southeast-3"
}

# 2. Create (or reference) a CodeCommit repository named "my-repo"
resource "aws_codecommit_repository" "my_repo" {
  repository_name = "my-repo"
  description     = "Repository for my application code."
}

# Generate a random suffix for the S3 bucket name
resource "random_id" "bucket_id" {
  byte_length = 4
}

# Create an S3 bucket for static website hosting
resource "aws_s3_bucket" "static_site" {
  bucket        = "static-website-${random_id.bucket_id.hex}"
  force_destroy = true

  tags = {
    Name = "StaticWebsite"
  }
}

# Configure the S3 bucket as a static website via separate resource
resource "aws_s3_bucket_website_configuration" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# Disable public access blocks so the bucket can serve public content
resource "aws_s3_bucket_public_access_block" "static_site_public_access" {
  bucket                  = aws_s3_bucket.static_site.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Allow public read for all objects in the bucket
data "aws_iam_policy_document" "public_read" {
  statement {
    sid       = "PublicReadGetObject"
    effect    = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static_site.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "static_site_policy" {
  bucket = aws_s3_bucket.static_site.id
  policy = data.aws_iam_policy_document.public_read.json
}


# 3. Local variables to capture all files under my-repo-contents/
locals {
  # Path to the folder containing your local code (relative to this Terraform module)
  repo_folder = "${path.module}/my-repo-contents"

  # Recursively find all files in the folder
  all_files = fileset(local.repo_folder, "**")
}


# Push hello.html into CodeCommit via AWS CLI
resource "null_resource" "push_hello" {
  # Re-run when hello.html changes
  triggers = {
    hello_sha = sha256(local_file.hello_page.content)
  }

  provisioner "local-exec" {
    command = <<EOF
set -e
REPO_NAME="${aws_codecommit_repository.my_repo.repository_name}"
BRANCH="main"
FILE_PATH="hello.html"
LOCAL_FILE="${path.module}/my-repo-contents/hello.html"

# Check if the branch exists
BRANCH_EXISTS=$(aws codecommit get-branch --repository-name "$REPO_NAME" --branch-name "$BRANCH" --query 'branch.branchName' --output text 2>/dev/null || echo "")

if [ "$BRANCH_EXISTS" = "$BRANCH" ]; then
  # Get the parent commit ID for overwriting
  PARENT_COMMIT=$(aws codecommit get-branch --repository-name "$REPO_NAME" --branch-name "$BRANCH" --query 'branch.commitId' --output text)
  aws codecommit put-file \
    --repository-name "$REPO_NAME" \
    --branch-name "$BRANCH" \
    --file-path "$FILE_PATH" \
    --file-content fileb://"$LOCAL_FILE" \
    --parent-commit-id "$PARENT_COMMIT" \
    --commit-message "Add or update $FILE_PATH" \
    --region ap-southeast-3
else
  # Initial commit on a new branch
  aws codecommit put-file \
    --repository-name "$REPO_NAME" \
    --branch-name "$BRANCH" \
    --file-path "$FILE_PATH" \
    --file-content fileb://"$LOCAL_FILE" \
    --commit-message "Add $FILE_PATH" \
    --region ap-southeast-3
fi
EOF
  }
}


#############################################
# CI/CD Pipeline: CodeCommit → S3 Static Site
#############################################

# 1. Create a dedicated S3 bucket for CodePipeline artifacts
resource "random_id" "pipeline_artifact_id" {
  byte_length = 4
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "pipeline-artifacts-${random_id.pipeline_artifact_id.hex}"
  force_destroy = true

  tags = {
    Name = "PipelineArtifacts"
  }
}

# 2. IAM role for CodePipeline
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

# 3. Attach a policy to allow CodePipeline to interact with CodeCommit, S3, and IAM
resource "aws_iam_role_policy" "codepipeline_policy" {
  name   = "codepipeline-policy"
  role   = aws_iam_role.codepipeline_role.id
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
          "codecommit:GetUploadArchiveStatus"
        ]
        Resource = aws_codecommit_repository.my_repo.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.static_site.arn}/*",
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.static_site.arn,
          aws_s3_bucket.pipeline_artifacts.arn
        ]
      }
    ]
  })
}

# 4. CodePipeline resource
resource "aws_codepipeline" "deploy_static_site" {
  name     = "deploy-static-site-pipeline"
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
    name = "Deploy"
    action {
      name             = "DeployToS3"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "S3"
      version          = "1"
      input_artifacts  = ["source_output"]
      configuration = {
        BucketName = aws_s3_bucket.static_site.bucket
        Extract    = "true"
      }
    }
  }
}