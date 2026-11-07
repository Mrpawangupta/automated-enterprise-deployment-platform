terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  # terraform.workspace IS the environment - one root config, three
  # workspaces (dev/stage/prod), rather than three duplicated directories.
  # `terraform workspace new stage && terraform workspace select stage`
  # before applying with environments/stage/stage.tfvars (see docs/runbooks.md).
  environment = terraform.workspace
  name_prefix = "analytics-${local.environment}"
  common_tags = {
    Project     = "enterprise-analytics"
    Environment = local.environment
    ManagedBy   = "terraform"
    Workspace   = terraform.workspace
  }
}

data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "tf_state" {
  bucket = "analytics-tf-state-${data.aws_caller_identity.current.account_id}"
}

data "aws_dynamodb_table" "tf_lock" {
  name = "analytics-tf-lock"
}

module "vpc_networking" {
  source = "./modules/vpc-networking"

  name_prefix        = local.name_prefix
  cluster_name       = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  tags               = local.common_tags
}

module "eks_cluster" {
  source = "./modules/eks-cluster"

  cluster_name          = local.name_prefix
  k8s_version           = var.k8s_version
  private_subnet_ids    = module.vpc_networking.private_subnet_ids
  public_access_enabled = var.eks_public_access_enabled
  public_access_cidrs   = var.eks_public_access_cidrs
  node_groups           = var.node_groups
  tags                  = local.common_tags
}

module "security_baseline" {
  source = "./modules/security-baseline"

  name_prefix         = local.name_prefix
  jenkins_role_arn    = var.jenkins_role_arn
  tf_state_bucket_arn = data.aws_s3_bucket.tf_state.arn
  tf_lock_table_arn   = data.aws_dynamodb_table.tf_lock.arn
  waf_rate_limit      = var.waf_rate_limit
  tags                = local.common_tags
}

module "monitoring_stack" {
  source = "./modules/monitoring-stack"

  name_prefix       = local.name_prefix
  cluster_name      = local.name_prefix
  aws_region        = var.aws_region
  alert_email       = var.alert_email
  slack_webhook_url = var.slack_webhook_url
  tags              = local.common_tags
}
