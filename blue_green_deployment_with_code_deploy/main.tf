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
      echo '<!DOCTYPE html><html><head><title>Hello</title></head><body><h1>Hello, World Test 2!</h1></body></html>' > index.html
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
  BeforeInstall:
    - location: cleanup_html.sh
      timeout: 60
      runas: root
  AfterInstall:
    - location: copy_html.sh
      timeout: 180
      runas: root
EOF
      cat > cleanup_html.sh <<EOF
#!/bin/bash
set -e
if [ -f /var/www/html/index.html ]; then
  rm -f /var/www/html/index.html
fi
EOF
      chmod +x cleanup_html.sh
      cat > copy_html.sh <<EOF
#!/bin/bash
set -e
DEPLOYMENT_ARCHIVE="/opt/codedeploy-agent/deployment-root/\$DEPLOYMENT_GROUP_ID/\$DEPLOYMENT_ID/deployment-archive"
echo "\$(date) \$RANDOM" >> /tmp/codedeploy_revision_marker.txt
mkdir -p /var/www/html
cp -f "\$DEPLOYMENT_ARCHIVE/index.html" /var/www/html/index.html
EOF
      chmod +x copy_html.sh
      # Push index.html
      aws codecommit put-file \
        --repository-name my-demo-repo \
        --branch-name master \
        --file-content fileb://index.html \
        --file-path index.html \
        --commit-message "Update index.html via Terraform" || true
      # Push appspec.yml, copy_html.sh, cleanup_html.sh using robust logic
      BRANCH_EXISTS=$(aws codecommit get-branch --repository-name my-demo-repo --branch-name master --query 'branch.branchName' --output text 2>/dev/null || echo "none")
      if [ "$BRANCH_EXISTS" = "none" ]; then
        # Initial commit with index.html
        aws codecommit put-file \
          --repository-name my-demo-repo \
          --branch-name master \
          --file-content fileb://index.html \
          --file-path index.html \
          --commit-message "Initial commit with index.html via Terraform"
      fi
      # Always get latest parent commit ID for each file
      for FILE in appspec.yml copy_html.sh cleanup_html.sh; do
        PARENT_ID=$(aws codecommit get-branch --repository-name my-demo-repo --branch-name master --query 'branch.commitId' --output text)
        aws codecommit put-file \
          --repository-name my-demo-repo \
          --branch-name master \
          --file-content fileb://$FILE \
          --file-path $FILE \
          --parent-commit-id $PARENT_ID \
          --commit-message "Update $FILE via Terraform" || true
      done
      # Trigger CodePipeline after files are pushed
      aws codepipeline start-pipeline-execution --name html-codedeploy-pipeline || true
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

resource "aws_subnet" "public2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[1]
  tags = {
    Name = "public-subnet-2"
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

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public.id
}

locals {
  ami_id = "ami-0b24d50858974f2ee"
}


# Security group for ALB
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Security Group for ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTP from anywhere"
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

  tags = {
    Name = "alb-sg"
  }
}

# Security group for EC2 instances (public)
resource "aws_security_group" "public_sg" {
  name        = "public-sg"
  description = "Allow traffic from ALB and SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow all from ALB"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "Allow SSH from everywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "Allow all traffic from itself"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    self        = true
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
  autoscaling_groups   = [aws_autoscaling_group.web_asg.name]

  deployment_style {
    deployment_type = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }
  blue_green_deployment_config {
    terminate_blue_instances_on_deployment_success {
      action = "TERMINATE"
      termination_wait_time_in_minutes = 1
    }
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
      wait_time_in_minutes = 0
    }
    green_fleet_provisioning_option {
      action = "COPY_AUTO_SCALING_GROUP"
    }
  }
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.app_tg.name
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

resource "aws_launch_template" "web_lt" {
  name_prefix   = "web-lt-"
  image_id      = local.ami_id
  instance_type = "t3.2xlarge"

  iam_instance_profile {
    name = aws_iam_instance_profile.codedeploy_instance_profile.name
  }

  vpc_security_group_ids = [aws_security_group.public_sg.id]

  user_data = base64encode(<<EOF
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
echo "<html><body><h1>Placeholder</h1></body></html>" | sudo tee /var/www/html/index.html
EOF
  )

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name  = "web-asg"
      Fleet = "blue"
    }
  }
}

resource "aws_autoscaling_group" "web_asg" {
  name                      = "web-asg"
  min_size                  = 1
  desired_capacity          = 2
  max_size                  = 10
  vpc_zone_identifier       = [aws_subnet.public.id, aws_subnet.public2.id]
  target_group_arns         = [aws_lb_target_group.app_tg.arn]

  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "web-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Fleet"
    value               = "blue"
    propagate_at_launch = true
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "bluegreen-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "bluegreen-app-tg"
  }
}

resource "aws_lb" "app_lb" {
  name               = "bluegreen-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public2.id]
  enable_deletion_protection = false
  tags = {
    Name = "bluegreen-app-lb"
  }
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

data "aws_availability_zones" "available" {}