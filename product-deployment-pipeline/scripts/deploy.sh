#!/bin/bash
set -eE

# Enterprise Deployment Script - manual/local equivalent of the Jenkinsfile.
# Usage: ./deploy.sh <environment: dev|stage|prod> <action: plan|apply|destroy> [image_tag] [run_tests] [security_scan]
# Run from the repo root.
# Required env var: TF_VAR_jenkins_role_arn (ARN of the Jenkins IAM principal)

ENVIRONMENT="${1:-dev}"
ACTION="${2:-apply}"
IMAGE_TAG="${3:-$(git rev-parse --short HEAD)}"
RUN_TESTS="${4:-true}"
SECURITY_SCAN="${5:-true}"

echo "Starting enterprise deployment"
echo "Environment: $ENVIRONMENT"
echo "Action: $ACTION"
echo "Image Tag: $IMAGE_TAG"

VALID_ENVIRONMENTS=("dev" "stage" "prod")
if [[ ! " ${VALID_ENVIRONMENTS[*]} " =~ " ${ENVIRONMENT} " ]]; then
    echo "ERROR: Invalid environment: $ENVIRONMENT (must be dev, stage, or prod)"
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="analytics-${ENVIRONMENT}"
API_HOST="${API_HOST:-api.analytics.company.com}"
WEB_HOST="${WEB_HOST:-app.analytics.company.com}"

check_prerequisites() {
    echo "Checking prerequisites..."
    required_commands=("docker" "terraform" "kubectl" "aws" "git" "jq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "ERROR: Required command not found: $cmd"
            exit 1
        fi
    done
    if ! docker info &> /dev/null; then
        echo "ERROR: Docker daemon not running"
        exit 1
    fi
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "ERROR: AWS credentials not configured"
        exit 1
    fi
    if [[ -z "$TF_VAR_jenkins_role_arn" ]]; then
        echo "ERROR: TF_VAR_jenkins_role_arn is not set (required by Terraform)"
        exit 1
    fi
    echo "All prerequisites satisfied"
}

# Derived after prerequisites so a missing AWS login fails early and clearly
# instead of silently producing an UNKNOWN_ACCOUNT bucket name.
set_account_config() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    TF_STATE_BUCKET="analytics-tf-state-${AWS_ACCOUNT_ID}"
}

confirm_action() {
    if [[ "$ACTION" == "destroy" ]] || [[ "$ACTION" == "apply" && "$ENVIRONMENT" == "prod" ]]; then
        echo "WARNING: you are about to run '$ACTION' on '$ENVIRONMENT'."
        read -r -p "Type the environment name ($ENVIRONMENT) to continue: " answer
        if [[ "$answer" != "$ENVIRONMENT" ]]; then
            echo "Confirmation did not match. Aborting."
            exit 1
        fi
    fi
}

# Static scans run BEFORE the build (they need only source/IaC).
run_static_scans() {
    if [[ "$SECURITY_SCAN" == "true" ]]; then
        echo "Running static security scans (Semgrep, Checkov)..."
        docker run --rm -v "$(pwd):/src" returntocorp/semgrep semgrep scan --config auto /src
        docker run --rm -v "$(pwd)/product-infrastructure:/iac" bridgecrew/checkov -d /iac
        echo "Static scans completed"
    fi
}

# Image scans run AFTER the build and BEFORE the push.
run_image_scans() {
    if [[ "$SECURITY_SCAN" == "true" ]]; then
        echo "Running Trivy image scans..."
        for image in "analytics-api" "analytics-web" "analytics-data-processor"; do
            echo "Scanning $image..."
            docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                aquasec/trivy:latest image --exit-code 1 --severity HIGH,CRITICAL \
                "$ECR_REGISTRY/$image:$IMAGE_TAG"
        done
        echo "Image scans completed"
    fi
}

build_images() {
    echo "Building Docker images (single multi-target Dockerfile in product-docker/)..."
    (
        cd product-docker
        docker build --target api            -t "$ECR_REGISTRY/analytics-api:$IMAGE_TAG" .
        docker build --target webapp         -t "$ECR_REGISTRY/analytics-web:$IMAGE_TAG" .
        docker build --target data-processor -t "$ECR_REGISTRY/analytics-data-processor:$IMAGE_TAG" .
    )
    echo "Images built"
}

push_images() {
    echo "Pushing images to ECR (immutable tag only, no :latest)..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
    for image in "analytics-api" "analytics-web" "analytics-data-processor"; do
        docker push "$ECR_REGISTRY/$image:$IMAGE_TAG"
    done
    echo "Images pushed"
}

run_tests() {
    if [[ "$RUN_TESTS" == "true" ]]; then
        if [[ -d app ]]; then
            echo "Running tests..."
            (cd app && mvn test)
            echo "Tests completed"
        else
            echo "SKIPPED: no app/ directory in this repo, so there is nothing to test."
        fi
    fi
}

deploy_infrastructure() {
    echo "Deploying infrastructure (workspace: $ENVIRONMENT)..."
    cd product-infrastructure

    terraform init \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="region=$AWS_REGION"

    terraform workspace select "$ENVIRONMENT" 2>/dev/null || terraform workspace new "$ENVIRONMENT"

    case $ACTION in
        "plan")
            terraform plan -var-file="environments/$ENVIRONMENT/$ENVIRONMENT.tfvars" -var="image_tag=$IMAGE_TAG"
            ;;
        "apply")
            terraform apply -auto-approve -var-file="environments/$ENVIRONMENT/$ENVIRONMENT.tfvars" -var="image_tag=$IMAGE_TAG"
            ;;
        "destroy")
            terraform destroy -auto-approve -var-file="environments/$ENVIRONMENT/$ENVIRONMENT.tfvars"
            ;;
        *)
            echo "ERROR: Invalid action: $ACTION (must be plan, apply, or destroy)"
            exit 1
            ;;
    esac

    if [[ "$ACTION" != "destroy" ]]; then
        terraform output -json > outputs.json
    fi
    cd ..
    echo "Infrastructure step completed"
}

deploy_kubernetes() {
    if [[ "$ACTION" == "apply" ]]; then
        echo "Deploying to Kubernetes..."
        aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
        kubectl create namespace analytics --dry-run=client -o yaml | kubectl apply -f -

        cd product-kubernetes
        # Render a temporary copy so the tracked deployment.yaml is never modified.
        sed -e "s#analytics-api:latest#$ECR_REGISTRY/analytics-api:$IMAGE_TAG#g" \
            -e "s#analytics-web:latest#$ECR_REGISTRY/analytics-web:$IMAGE_TAG#g" \
            -e "s#analytics-data-processor:latest#$ECR_REGISTRY/analytics-data-processor:$IMAGE_TAG#g" \
            deployment.yaml > deployment.rendered.yaml

        kubectl apply -f configmap.yaml

        # secrets.yaml is a placeholder template; never overwrite real secrets.
        if kubectl get secret api-secrets -n analytics &> /dev/null; then
            echo "Secret api-secrets already exists - not overwriting."
        else
            echo "WARNING: api-secrets not found, applying placeholder template. Populate real values before use."
            kubectl apply -f secrets.yaml
        fi

        kubectl apply -f deployment.rendered.yaml
        kubectl apply -f service.yaml
        kubectl apply -f ingress.yaml
        rm -f deployment.rendered.yaml

        kubectl wait --for=condition=available --timeout=300s deployment/analytics-api -n analytics
        kubectl wait --for=condition=available --timeout=300s deployment/analytics-web -n analytics

        cd ..
        echo "Kubernetes deployment completed"
    fi
}

# Checks one URL; returns 0 on success, 1 if it never became healthy.
check_endpoint() {
    local name=$1 lb=$2 host=$3 path=$4
    for _ in {1..30}; do
        if curl -fsk -H "Host: $host" "https://$lb$path" &> /dev/null; then
            echo "$name health check passed"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: $name health check FAILED after 30 attempts"
    return 1
}

run_smoke_tests() {
    if [[ "$ACTION" == "apply" ]]; then
        echo "Running smoke tests..."
        local failed=0
        API_LB=$(kubectl get ingress analytics-api -n analytics -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        WEB_LB=$(kubectl get ingress analytics-web -n analytics -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

        if [[ -z "$API_LB" || -z "$WEB_LB" ]]; then
            echo "ERROR: ALB hostname not available yet for one or both ingresses"
            return 1
        fi

        check_endpoint "API" "$API_LB" "$API_HOST" "/actuator/health" || failed=1
        check_endpoint "Web" "$WEB_LB" "$WEB_HOST" "/health" || failed=1

        if [[ $failed -ne 0 ]]; then
            return 1
        fi
        echo "Smoke tests passed"
    fi
}

send_notification() {
    local status=$1
    local message=$2
    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"Deployment $status: $message\"}" "$SLACK_WEBHOOK_URL" || true
    fi
    mkdir -p logs
    echo "$(date): $status - $message" >> "logs/deployments.log"
}

main() {
    START_TIME=$(date +%s)
    trap 'send_notification "FAILED" "Deployment failed for $ENVIRONMENT"' ERR

    check_prerequisites
    set_account_config
    confirm_action

    if [[ "$ACTION" == "apply" ]]; then
        run_tests
        run_static_scans
        build_images
        run_image_scans
        push_images
    fi

    deploy_infrastructure
    deploy_kubernetes
    run_smoke_tests

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    send_notification "SUCCESS" "Deployment completed for $ENVIRONMENT in ${DURATION}s"
    echo "Deployment completed successfully! (${DURATION}s)"
}

main