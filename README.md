# Automated Enterprise Deployment Platform: Review, Fixes and Documentation

**Name:** Pawan Kumar
**Course:** DevOps with AI (SkillFyMe)
**Assignment:** Capstone & Career Prep, Project 1 (Automated Enterprise Deployment Platform)
**GitHub:** [Mrpawangupta](https://github.com/Mrpawangupta)

> The base platform (Terraform, Kubernetes, Docker, Jenkins and monitoring files) was provided by the course (see `ORIGINAL-README.md`). This README documents what I reviewed, what I fixed and how to run it.

---

## 1. Problem Statement Overview

Enterprises need a repeatable, secure and automated way to deploy applications. This project provides a deployment platform on AWS with:

- **Infrastructure as Code:** Terraform modules for VPC, EKS, security baseline (KMS, Secrets Manager, WAF, CI role) and monitoring (SNS, CloudWatch).
- **Containerisation:** a multi-stage, multi-target Dockerfile for three components (API, web app, data processor).
- **Kubernetes manifests:** deployments, services, ingress and a CronJob.
- **CI/CD:** a Jenkins pipeline and local deploy/rollback scripts with security scanning (SonarQube, Trivy, Checkov), approval gate and rollback.
- **Observability:** EFK logging stack and Prometheus/Grafana monitoring.

The task was to understand this platform, find the gaps between what it claims and what the code actually does, and fix them.

## 2. Solution Approach

I reviewed the main components (`product-docker`, `product-kubernetes`, `product-infrastructure`, the Jenkinsfile and the deploy/rollback scripts, the monitoring configs, and the security and runbook docs) and fixed the issues I could verify or confidently correct. `health-check.sh`, `notify-slack.sh`, `shared-library/` and some architecture docs were not reviewed. Each fix is a separate commit with a clear message.

| # | Area | Fix | Why |
|---|------|-----|-----|
| 1 | Terraform | Replaced `taint = ...` with a `dynamic "taint"` block (EKS node group) and changed `domain = "vpc"` to `vpc = true` (aws_eip) | `terraform validate` failed with these two errors on AWS provider 4.x |
| 2 | Repo hygiene | Added Terraform local files and state to `.gitignore` | Avoid committing `.terraform/` and state files |
| 3 | Docker | Replaced the deprecated `openjdk` base image, fixed the nginx `HEALTHCHECK` (`curl` is not in alpine, so `wget`), bumped nginx to 1.27 | Deprecated image and a healthcheck that could never pass |
| 4 | Kubernetes Ingress | Used `ingressClassName`, shared one ALB through `group.name`, added HTTP to HTTPS redirect | Deprecated annotation, double ALB cost, no redirect |
| 5 | Kubernetes security | Added `runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation: false`, dropped all capabilities, and a read-only root filesystem for the API | Pod hardening was incomplete, and the CronJob had no securityContext |
| 6 | `rollback.sh` | Switches kubeconfig to the target environment's cluster before rolling back | The script rolled back whichever cluster was current |
| 7 | `deploy.sh` | Smoke tests now actually fail, destroy/prod apply need confirmation, Trivy runs after build and before push, `:latest` is no longer pushed, existing secrets are not overwritten, AWS account ID is derived instead of hardcoded | Several behaviours contradicted the documented guarantees |
| 8 | `Jenkinsfile` | Each step runs in the correct tool container, `withVault` has a body, `IMAGE_TAG` default fixed, scan order corrected, quality gate is blocking, destroy has its own approval stage, rollback only runs on prod after the deploy stage started, `retry(3)` removed | The pipeline would have failed or behaved unsafely in several places |

### Proof (Terraform validate)

| Before | After |
|--------|-------|
| 2 errors (unsupported `taint` argument, `domain` on `aws_eip`) | `Success! The configuration is valid.` |

Screenshots: `docs/proof/terraform-validate-before.png` and `docs/proof/terraform-validate-after.png`

## 3. Dependencies and Setup Instructions

**Needed to review and validate (what I used):**

- Git
- Terraform (>= 1.0; AWS provider `~> 4.0`)
- VS Code (optional)

**Additionally needed for a real deployment:**

- AWS account with credentials configured (`aws configure`)
- AWS CLI, kubectl, Helm, jq
- Docker (Docker Desktop on Windows)
- Jenkins with the Kubernetes and HashiCorp Vault plugins, plus SonarQube, if using the pipeline
- Pre-created S3 state bucket `analytics-tf-state-<account-id>` and DynamoDB lock table `analytics-tf-lock` (see `docs/runbooks.md`)
- Application source and files the Dockerfile expects (`target/*.jar`, `application-prod.yml`, `nginx.conf`, `mime.types`, `dist/`), which are not part of this repository

## 4. Execution Steps

**A. Validate the infrastructure code (no AWS account needed)**

```bash
git clone https://github.com/Mrpawangupta/automated-enterprise-deployment-platform.git
cd automated-enterprise-deployment-platform
Screenshot: `docs/proof/terraform-validate-after.png`
cd product-infrastructure
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
```

Expected output: `Success! The configuration is valid.`

**B. Syntax-check the scripts (Git Bash or WSL)**

```bash
bash -n product-deployment-pipeline/scripts/deploy.sh
bash -n product-deployment-pipeline/scripts/rollback.sh
```

**C. Full deployment (requires AWS, Docker and the app source)**

```bash
export TF_VAR_jenkins_role_arn=<arn-of-jenkins-iam-principal>
./product-deployment-pipeline/scripts/deploy.sh dev plan
./product-deployment-pipeline/scripts/deploy.sh dev apply
```

Roll back an environment:

```bash
./product-deployment-pipeline/scripts/rollback.sh dev
```

> Running `apply` on AWS creates billable resources (EKS control plane, nodes, NAT gateway). Use `plan` first and destroy dev resources when done.

## Known Limitations (honest status)

- **Verified:** `terraform init -backend=false`, `terraform fmt` and `terraform validate`.
- **Reviewed and fixed, but not executed:** `Jenkinsfile`, `deploy.sh`, `rollback.sh`, Kubernetes manifests and Dockerfile changes. They need AWS, Jenkins, Vault and the application source to be run end to end.
- Placeholder values remain: `company.com` hostnames, Vault and SonarQube URLs, ACM certificate ARN.
- Not fixed yet: monitoring Helm values (Alertmanager nesting, rule keys, metric names), EKS add-ons (EBS CSI driver), WAF attachment to the ALB, ECR repository creation, `aws-auth` mapping for the CI role.
- Elasticsearch security settings and Elasticsearch/Kibana resource sizing for dev are not addressed.
- Not reviewed: `health-check.sh`, `notify-slack.sh`, `shared-library/`.

## Repository Layout

```
product-docker/                  Dockerfile and build scripts
product-kubernetes/              Deployments, services, ingress, configmap
product-infrastructure/          Terraform root and modules
product-deployment-pipeline/     Jenkinsfile and deploy/rollback scripts
monitoring/                      EFK and Prometheus/Grafana configs
docs/                            Architecture, runbooks, security guides
ORIGINAL-README.md               Original course README
```