

# CI/CD Pipeline for ECS Deployment

## Goals
- **Automate Application Updates**  
  Whenever code is pushed to CodeCommit, trigger a build-and-deploy workflow automatically.
- **Continuous Delivery**  
  Use CodeCommit → CodeBuild → Amazon ECR → Amazon ECS to deliver containerized changes with zero manual intervention.
- **ECR Image Cleanup**  
  Attach a lifecycle policy to the ECR repository so that only the **latest** Docker image remains (older images are removed automatically).
- **Application Accessibility**  
  After deployment, verify the ECS task’s public IP and expose the app on port **8501** (mapped from container port 8501 to host port 8501).

---

## Executions

### 1. Source Control: AWS CodeCommit
1. **Create a CodeCommit repository** (e.g., `ecs-app-repo`).
2. **Clone** the repository locally:
   ```bash
   git clone https://git-codecommit.<region>.amazonaws.com/v1/repos/ecs-app-repo
   cd ecs-app-repo
   ```
3. **Add your application code** (e.g., `app.py`, `Dockerfile`, and Terraform/CloudFormation files for ECS, ECR, IAM, etc.).
4. **Commit & Push**:
   ```bash
   git add .
   git commit -m "Initial commit for ECS CI/CD pipeline"
   git push origin main
   ```
5. On each push to `main`, CodeBuild will be triggered automatically (see the webhook/trigger configuration in your CodeBuild project).

---

### 2. Build & Push Docker Image: AWS CodeBuild
1. **Define a `buildspec.yml`** at the root of your repo. Example:
   ```yaml
   version: 0.2

   phases:
     pre_build:
       commands:
         - echo Logging in to Amazon ECR...
         - aws --version
         - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
         - REPOSITORY_URI=$ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/ecs-app-repo
         - IMAGE_TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
     build:
       commands:
         - echo Build started on `date`
         - echo Building the Docker image...
         - docker build -t $REPOSITORY_URI:latest .
         - docker tag $REPOSITORY_URI:latest $REPOSITORY_URI:$IMAGE_TAG
     post_build:
       commands:
         - echo Build completed on `date`
         - echo Pushing the Docker image...
         - docker push $REPOSITORY_URI:latest
         - docker push $REPOSITORY_URI:$IMAGE_TAG
         - printf '[{"name":"ecs-app-container","imageUri":"%s"}]' $REPOSITORY_URI:$IMAGE_TAG > imagedefinitions.json
   artifacts:
     files: imagedefinitions.json
   ```

---

### 3. Configure ECR Lifecycle Rule
1. **Navigate** to the ECR console and choose your repository (e.g., `ecs-app-repo`).
2. Under **“Lifecycle policies”**, click **“Add lifecycle policy”**.
3. **Use the following rule** (JSON editor or built-in wizard):
   ```json
   {
     "rules": [
       {
         "rulePriority": 1,
         "description": "Keep only the latest image",
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
   ```
4. **Save** the rule. This ensures that whenever a new image is pushed, only the most recent one remains; older images are pruned automatically.

---

### 4. Deploy to Amazon ECS
1. **Define your ECS cluster and service** (using Terraform, CloudFormation, or the console):
   - Create a VPC, subnets, and security groups that allow traffic on port 8501.
   - Create an ECS cluster (e.g., `ecs-app-cluster`).
   - Create a Task Definition named `ecs-app-task`:
     - Container name: `ecs-app-container`
     - Image: `${ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/ecs-app-repo:latest`
     - Port mapping: Container port 8501 → Host port 8501
   - Create an ECS Service (`ecs-app-service`) type “FARGATE” or “EC2”:
     - Attach the existing task definition (`ecs-app-task`).
     - Desired count: 1 (or as needed).
     - Assign to the cluster `ecs-app-cluster`.
   - Ensure the service’s security group allows inbound TCP on port 8501 (0.0.0.0/0 for public access, or tighter CIDR as needed).
2. **Update the service** whenever a new image is pushed:
   - The `imagedefinitions.json` artifact from CodeBuild can be used in a CodePipeline deploy stage, which updates the ECS service with the new task definition revision and image.

---

### 5. Verify Application on Port 8501
1. **Find the ECS Task’s Public IP**:
   - Go to the ECS console → Clusters → `ecs-app-cluster` → Tasks.
   - Click the running task to view details → Network → “Public IP” (if using the `awsvpc` network mode with a public subnet).
2. **Open Your Browser**:
   - Navigate to `http://<TASK_PUBLIC_IP>:8501`.
   - You should see your application up and running on port 8501.
3. **Optional: Use a Load Balancer**  
   For production, configure an Application Load Balancer (ALB) or Network Load Balancer (NLB) to route port 80 (HTTP) or 443 (HTTPS) to 8501 on your ECS service.  

---

## Folder Structure Overview
```
├── buildspec.yml
├── Dockerfile
├── main.tf
├── README.md
├── app.py
└── terraform/              # (if using Terraform)
    ├── ecs-cluster.tf
    ├── ecs-service.tf
    ├── ecr-repo.tf
    ├── vpc.tf
    └── iam-roles.tf
```

- **buildspec.yml**: Defines CodeBuild build steps for building and pushing Docker images.  
- **Dockerfile**: Contains instructions to containerize your application.  
- **main.tf** (or `*.tf` files under `terraform/`): Infrastructure-as-Code definitions for VPC, ECS, ECR, IAM, etc.  
- **app.py**: Your application entrypoint (e.g., a Streamlit app listening on port 8501).  

---

## Troubleshooting & Tips
- **CodeBuild Permissions**: Ensure the CodeBuild service role has permissions to:
  - `ecr:GetAuthorizationToken`
  - `ecr:BatchCheckLayerAvailability`
  - `ecr:CompleteLayerUpload`
  - `ecr:InitiateLayerUpload`
  - `ecr:PutImage`
  - `ecr:UploadLayerPart`
  - `ecr:BatchGetImage`
- **ECS Service Failing to Pull Image**:  
  - Verify that the ECR repository URI in your task definition matches exactly.  
  - Confirm the ECS task role or instance role has `ecr:GetAuthorizationToken` and `ecr:BatchGetImage` permissions.
- **Port 8501 Connectivity**:  
  - Make sure the security group attached to the ECS service allows inbound TCP on 8501.
  - If using an ALB/NLB, ensure the listener and target group are configured for port 8501.