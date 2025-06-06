terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "aws" {
  region = "ap-southeast-3"
}

resource "aws_codecommit_repository" "my_repo" {
  repository_name = "my-demo-repo"
  description     = "Repository for automation code"
  default_branch  = "master"
}

output "codecommit_clone_url_http" {
  value = aws_codecommit_repository.my_repo.clone_url_http
}

output "codecommit_clone_url_ssh" {
  value = aws_codecommit_repository.my_repo.clone_url_ssh
}

resource "null_resource" "init_codecommit_repo" {
  provisioner "local-exec" {
    command = <<EOT
      echo "# Initial commit" > README.md
      aws codecommit put-file \
        --repository-name my-demo-repo \
        --branch-name master \
        --file-content fileb://README.md \
        --file-path README.md \
        --commit-message "Initial commit with README.md" || true
    EOT
  }
}

resource "null_resource" "create_hello_world_html" {
  depends_on = [null_resource.init_codecommit_repo]
  triggers = {
    always_run = uuid()
  }
  provisioner "local-exec" {
    command = <<EOT
      echo '<!DOCTYPE html><html><head><title>Hello</title></head><body><h1>Hello, World!</h1></body></html>' > index.html
      PARENT_ID=$(aws codecommit get-branch --repository-name my-demo-repo --branch-name master --query 'branch.commitId' --output text)
      aws codecommit put-file \
        --repository-name my-demo-repo \
        --branch-name master \
        --file-content fileb://index.html \
        --file-path index.html \
        --parent-commit-id $PARENT_ID \
        --commit-message "Update index.html via Terraform" || true
    EOT
  }
}

resource "null_resource" "create_appspec_and_scripts" {
  triggers = {
    always_run = uuid()
  }
  provisioner "local-exec" {
    command = <<EOT
      cat > appspec.yml <<EOF
version: 0.0
os: linux
files:
  - source: index.html
    destination: /var/www/html/
hooks:
  AfterInstall:
    - location: copy_html.sh
      timeout: 180
      runas: root
EOF
      cat > copy_html.sh <<EOF
#!/bin/bash
set -e
DEPLOYMENT_ARCHIVE="/opt/codedeploy-agent/deployment-root/\$DEPLOYMENT_GROUP_ID/\$DEPLOYMENT_ID/deployment-archive"
echo "\$(date) \$RANDOM" >> /tmp/codedeploy_revision_marker.txt
mkdir -p /var/www/html
cp -f "\$DEPLOYMENT_ARCHIVE/index.html" /var/www/html/index.html
EOF
      chmod +x copy_html.sh
      aws codecommit put-file \
        --repository-name my-demo-repo \
        --branch-name master \
        --file-content fileb://appspec.yml \
        --file-path appspec.yml \
        --parent-commit-id $(aws codecommit get-branch --repository-name my-demo-repo --branch-name master --query 'branch.commitId' --output text) \
        --commit-message "Add appspec.yml via Terraform" || true
      aws codecommit put-file \
        --repository-name my-demo-repo \
        --branch-name master \
        --file-content fileb://copy_html.sh \
        --file-path copy_html.sh \
        --parent-commit-id $(aws codecommit get-branch --repository-name my-demo-repo --branch-name master --query 'branch.commitId' --output text) \
        --commit-message "Add copy_html.sh via Terraform" || true
    EOT
  }
  depends_on = [null_resource.create_hello_world_html]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "main-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags = {
    Name = "public-subnet"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

locals {
  ami_id = "ami-0b24d50858974f2ee"
}

resource "aws_security_group" "public_sg" {
  name        = "public-sg"
  description = "Allow SSH and ICMP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "public-sg"
  }
}

resource "aws_iam_role" "codedeploy_service" {
  name = "codedeploy-service-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "codedeploy.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy_service_attach" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

resource "aws_iam_role_policy_attachment" "codedeploy_service_pipeline" {
  role       = aws_iam_role.codedeploy_service.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_codedeploy_app" "app" {
  name = "html-app"
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "dg" {
  app_name              = aws_codedeploy_app.app.name
  deployment_group_name = "html-app-one"
  service_role_arn      = aws_iam_role.codedeploy_service.arn
  deployment_style {
    deployment_type = "IN_PLACE"
    deployment_option = "WITHOUT_TRAFFIC_CONTROL"
  }
  ec2_tag_set {
    ec2_tag_filter {
      key   = "Name"
      type  = "KEY_AND_VALUE"
      value = "web-1"
    }
    ec2_tag_filter {
      key   = "Name"
      type  = "KEY_AND_VALUE"
      value = "web-2"
    }
  }
}

resource "aws_iam_role" "codedeploy_instance" {
  name = "codedeploy-ec2-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy_instance_attach" {
  role       = aws_iam_role.codedeploy_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforAWSCodeDeploy"
}

resource "aws_iam_instance_profile" "codedeploy_instance_profile" {
  name = "codedeploy-ec2-instance-profile"
  role = aws_iam_role.codedeploy_instance.name
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket = "html-codedeploy-artifacts-${random_id.suffix.hex}"
  force_destroy = true
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_iam_role" "codepipeline_service" {
  name = "codepipeline-service-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "codepipeline.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codepipeline_service_attach" {
  role       = aws_iam_role.codepipeline_service.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_codepipeline" "html_pipeline" {
  name     = "html-codedeploy-pipeline"
  role_arn = aws_iam_role.codepipeline_service.arn

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
        BranchName     = "master"
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      input_artifacts = ["source_output"]
      version         = "1"
      configuration = {
        ApplicationName     = aws_codedeploy_app.app.name
        DeploymentGroupName = aws_codedeploy_deployment_group.dg.deployment_group_name
      }
    }
  }
}

resource "aws_instance" "web" {
  count         = 2
  ami           = local.ami_id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.public_sg.id]
  associate_public_ip_address = true
  iam_instance_profile = aws_iam_instance_profile.codedeploy_instance_profile.name
  tags = {
    Name = "web-${count.index + 1}"
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }
  user_data = <<-EOF
    #!/bin/bash
    set -e
    sudo yum update -y
    sudo yum install -y ruby wget
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
      AGENT_URL="https://aws-codedeploy-ap-southeast-3.s3.ap-southeast-3.amazonaws.com/latest/codedeploy-agent.noarch.rpm"
    else
      AGENT_URL="https://aws-codedeploy-ap-southeast-3.s3.ap-southeast-3.amazonaws.com/latest/codedeploy-agent.arm64.rpm"
    fi
    sudo yum install -y $AGENT_URL
    sudo systemctl enable codedeploy-agent
    sudo systemctl start codedeploy-agent
    sudo yum install -y httpd
    sudo systemctl enable httpd
    sudo systemctl start httpd
    sudo systemctl status httpd
  EOF
}

data "aws_availability_zones" "available" {}
