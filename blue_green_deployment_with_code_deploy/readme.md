# 🚀 Blue/Green Deployment with AWS CodeDeploy & Terraform

## Goal
Simulate a blue/green deployment pipeline on AWS, deploying one environment at a time, using:
- Auto Scaling Group (ASG)
- Application Load Balancer (ALB)
- AWS CodeDeploy (with blue/green strategy)
- AWS CodePipeline
- All managed via Terraform

---

## What We Did (Step-by-Step)

1. **Infrastructure as Code (IaC) Setup**
   - Defined all AWS resources in `main.tf` using Terraform.
   - Used a single ASG and ALB for scalable, load-balanced deployments.

2. **Source Control & Artifacts**
   - Created an AWS CodeCommit repository for storing deployment files.
   - Automated pushing of all generated files (index.html, appspec.yml, scripts) to CodeCommit on every stack update.

3. **Launch Template & ASG**
   - Configured a launch template with user_data to install CodeDeploy agent and httpd, and create a placeholder index.html for health checks.
   - ASG provisions EC2 instances using this template.

4. **ALB & Target Group**
   - Set up an Application Load Balancer and target group for routing traffic to healthy EC2 instances.
   - Health checks ensure only healthy instances receive traffic.

5. **CodeDeploy Blue/Green Deployment**
   - Configured CodeDeploy deployment group for blue/green deployments using the `COPY_AUTO_SCALING_GROUP` option.
   - Added lifecycle hooks and scripts:
     - `cleanup_html.sh` (BeforeInstall): Removes any existing index.html to avoid conflicts.
     - `copy_html.sh` (AfterInstall): Copies the new index.html from the deployment archive.

6. **CI/CD Pipeline**
   - Set up AWS CodePipeline to automate deployments from CodeCommit to CodeDeploy.
   - Pipeline is automatically triggered after every stack update.

7. **Automation & Robustness**
   - Provisioners ensure all relevant files are always pushed to CodeCommit, even if the repo/branch is empty.
   - CodePipeline is always triggered after updates for continuous delivery.

---

## 🟦🟩 Blue/Green Simulation
- Deployments are performed one environment at a time (blue or green), with traffic shifting managed by CodeDeploy.
- Health checks and lifecycle scripts ensure zero-downtime and smooth file replacement.

---

## How to Use
1. Update the stack with `terraform apply`.
2. All deployment files are pushed to CodeCommit.
3. CodePipeline is triggered, which runs a blue/green deployment via CodeDeploy.
4. ALB routes traffic to the healthy, newly deployed environment.

---

Enjoy safe, automated blue/green deployments! 💚💙
