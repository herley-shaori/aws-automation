

# Static Website CI/CD with S3 🚀

## Goals 🎯
- **Host** a static website on Amazon S3.
- **Automate** deployments using AWS CodeCommit and AWS CodePipeline.
- **Practice** Terraform-based infrastructure-as-code for reproducibility.
- **Demonstrate** how a change to the HTML file triggers a pipeline that deploys to S3.

---

## Architecture Overview 🏗️

Below is an ASCII diagram illustrating how everything fits together:

```
      +----------------------+  
      |  Local Terraform     |  
      |  (generate hello.html|  
      |   and push to CC)    |  
      +----------+-----------+  
                 |  
                 v  
      +----------------------+  
      |  AWS CodeCommit      |  
      |  (my-repo: main)     |  
      +----------+-----------+  
                 |  
                 v  
      +----------------------+  
      |  AWS CodePipeline    |  
      |  (Source → Deploy)   |  
      +----------+-----------+  
                 |  
      (Deploy Stage:     |
       extract files to  |
       S3 bucket)        |
                 v  
      +----------------------+  
      |  Amazon S3 Bucket    |  
      |  (static-website-*)  |  
      |  (public website)    |  
      +----------------------+  
```

---

## Prerequisites ✔️
1. **AWS CLI** installed and configured (with permissions for CodeCommit, CodePipeline, S3, IAM, etc.).
2. **Terraform (v1.0 or later)** installed.
3. **AWS Account** in the Jakarta (`ap-southeast-3`) region.
4. **Git** (optional, since Terraform pushes files via AWS CLI).
5. Ensure you have run `terraform init` successfully.

---

## Files & Structure 📁
```
static_website_cicd_with_s3/
├── main.tf
├── deploy.sh
├── destroy.sh
├── readme.md
└── my-repo-contents/
    └── hello.html          ← The HTML file generated/pushed via Terraform
```

- **`main.tf`**: Contains Terraform code to:
  - Create a CodeCommit repository (`my-repo`).
  - Generate `hello.html` with a configurable greeting.
  - Push `hello.html` into CodeCommit (via AWS CLI in a `null_resource`).
  - Create the S3 bucket, bucket policy, and website configuration.
  - Create a CodePipeline (Source → Deploy to S3).
- **`deploy.sh`**: Runs `terraform init` and `terraform apply`.
- **`destroy.sh`**: Runs `terraform destroy` to clean up all resources.
- **`readme.md`**: (This file) describes goals, steps, and usage.
- **`my-repo-contents/hello.html`**: The local file that is versioned and deployed.

---

## Setup & Deployment Steps 🔧

1. **Clone the Repository**  
   ```bash
   git clone <your-terraform-repo-url>.git
   cd static_website_cicd_with_s3
   ```

2. **Initialize Terraform**  
   ```bash
   ./deploy.sh
   ```
   - This script calls:
     ```
     terraform init
     terraform apply -auto-approve
     ```
   - Terraform will:
     1. Create a CodeCommit repo (`my-repo`).
     2. Generate `my-repo-contents/hello.html` with the default greeting.
     3. Push `hello.html` into `my-repo` (branch `main`).
     4. Create an S3 bucket prefixed with `static-website-`.
     5. Configure the bucket for static website hosting.
     6. Create an S3 bucket for pipeline artifacts.
     7. Create a CodePipeline that watches `my-repo:main` and deploys to the S3 bucket.

3. **Verify the Pipeline**  
   - Open the AWS Console → **CodePipeline** → `deploy-static-site-pipeline`.
   - Confirm the pipeline stages:
     1. **Source** (from CodeCommit: `my-repo/main`)
     2. **Deploy** (Deploy to S3: static bucket).
   - You should see the initial execution succeed and the `hello.html` object appear in the S3 bucket.

4. **View the Static Website**  
   - Go to the S3 bucket in the AWS Console → **Properties** → **Static website hosting**.
   - Note the **Endpoint** URL (e.g., `http://static-website-5b4ab1f2.s3-website-ap-southeast-3.amazonaws.com`).
   - Open that URL in your browser to see:
     > **Hello, World!**  
     > This file was pushed to CodeCommit via Terraform.

---

## Updating the Greeting ✏️

1. **Change the `greeting_text` variable** in Terraform (either by editing `main.tf` or using a `-var` flag):
   ```bash
   terraform apply -var="greeting_text='Hello, Terraform!'" -auto-approve
   ```
   - Terraform will regenerate `hello.html` with the new greeting.
   - The `null_resource` detects the content change (via SHA256), pushes to CodeCommit, and triggers a new pipeline execution.

2. **Manual Trigger (Release Change Button)**  
   - Sometimes, the pipeline does not auto-start immediately.  
   - In the AWS Console → **CodePipeline** → select `deploy-static-site-pipeline`.  
   - Click the **“Release change”** (▶️) button to manually start the pipeline.
   - Once the Deploy stage completes, refresh your website URL to see the updated greeting.

---

## Cleanup & Teardown 🧹

1. **Destroy all resources**  
   ```bash
   ./destroy.sh
   ```
   - This runs `terraform destroy -auto-approve`, which:
     1. Deletes the pipeline.
     2. Deletes IAM roles and policies.
     3. Deletes both S3 buckets (pipeline artifacts & static site) and all contained objects (because `force_destroy = true`).
     4. Deletes the CodeCommit repository and any commits.

2. **Confirm Deletion**  
   - After completion, confirm in the AWS Console that:
     - `my-repo` (CodeCommit) is gone.
     - Both S3 buckets are removed.
     - The IAM role no longer exists.
     - CodePipeline entry is gone.

---

## Troubleshooting & Tips 🔍

- **Pipeline Stuck?**  
  - Check IAM role permissions for missing CodeCommit actions (e.g., `UploadArchive`, `GetUploadArchiveStatus`).
  - Ensure your AWS CLI credentials have permission to read/write CodeCommit and S3.

- **No Website Content in S3?**  
  - Verify that the pipeline executed successfully.
  - Confirm that `hello.html` is present under the “Objects” tab of the static site bucket.
  - Make sure the bucket’s static website configuration points to `index.html` or `hello.html` (as desired).

- **Custom Domain?**  
  - If you want a custom domain, configure Route 53 and a Certificate Manager certificate. Then update the S3 bucket configuration and possibly CloudFront. This example focuses on the basics.

---

🎉 **Congratulations!** You now have a fully automated, Terraform-driven CI/CD pipeline that publishes a static website to S3. Enjoy experimenting and extending this pattern to more complex applications! 🚀