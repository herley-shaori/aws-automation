

# 🚀 AWS CodeDeploy "All at Once" Simulation

This repository demonstrates an end-to-end AWS CodeDeploy simulation using Terraform! 🌟

## 🎯 Goal
- Simulate AWS CodeDeploy setup and deployment process.
- Automate infrastructure provisioning and deployment through Terraform.

## 🛠️ What's Included?
- **EC2 Instances**: Provisioned and managed for blue/green deployment.
- **Application Load Balancer (ALB)**: Routes traffic between deployments.
- **Target Groups**: Blue and Green groups to manage deployment shifts.
- **IAM Roles and Policies**: Securely manage permissions for AWS resources.

## 🚦 Deployment Strategy
- **Blue/Green Deployment**: Safely shift traffic between two environments to minimize downtime.
- Real-time switching between deployments for zero-downtime updates. 🔄

## 📦 Technologies Used
- Terraform ☁️
- AWS EC2 🖥️
- AWS CodeDeploy 📜
- AWS ALB 🌐

## 🎉 Getting Started
1. Clone the repository.
2. Run Terraform commands:
   ```bash
   terraform init
   terraform apply
   ```
3. Watch your infrastructure and deployment automatically set up! ✅

Enjoy automating! 🤖✨