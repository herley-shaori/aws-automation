#!/usr/bin/env bash
set -euo pipefail

# Initialize Terraform (download providers, etc.)
terraform init

# Plan & apply in one go, auto-approve so no interactive prompt
terraform apply -auto-approve