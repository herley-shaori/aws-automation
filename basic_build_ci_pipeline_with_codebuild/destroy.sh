#!/usr/bin/env bash
set -euo pipefail

# Tear everything down without prompts
terraform destroy -auto-approve