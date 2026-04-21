#!/bin/bash
# Deploy Lambda code packages after Terraform has created the functions.

set -euo pipefail

AWS_REGION=${AWS_REGION:-us-east-1}
PROJECT_NAME=${PROJECT_NAME:-crisis-pulse}

deploy_lambda() {
  local function_name="$1"
  local source_dir="$2"
  local zip_file="/tmp/${function_name}.zip"

  echo ""
  echo "Packaging ${function_name} from ${source_dir}"
  cd "$source_dir"

  rm -rf package
  mkdir -p package

  if [ -f requirements.txt ]; then
    pip install -r requirements.txt -t ./package --quiet
  fi

  cp handler.py ./package/
  cd package
  zip -r "$zip_file" . --quiet

  echo "Deploying ${PROJECT_NAME}-${function_name}"
  aws lambda update-function-code \
    --function-name "${PROJECT_NAME}-${function_name}" \
    --zip-file "fileb://${zip_file}" \
    --region "$AWS_REGION" \
    --output text \
    --query "FunctionName" \
    2>/dev/null || echo "Function ${PROJECT_NAME}-${function_name} not found. Run terraform apply first."
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

deploy_lambda "classifier" "$REPO_ROOT/lambdas/classifier"
deploy_lambda "api-handler" "$REPO_ROOT/lambdas/api_handler"
deploy_lambda "alert-engine" "$REPO_ROOT/lambdas/alert_engine"

echo ""
echo "Lambda deployment complete."
