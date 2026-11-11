module "vpc" {
  source = "./modules/vpc"

  cluster_name         = var.cluster_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "eks" {
  source = "./modules/eks"

  cluster_name                         = var.cluster_name
  cluster_version                      = var.cluster_version
  environment                          = var.environment
  vpc_id                               = module.vpc.vpc_id
  public_subnet_ids                    = module.vpc.public_subnet_ids
  private_subnet_ids                   = module.vpc.private_subnet_ids
  node_instance_types                  = var.node_instance_types
  node_desired_size                    = var.node_desired_size
  node_min_size                        = var.node_min_size
  node_max_size                        = var.node_max_size
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
}

# Post-apply cluster configuration (kubeconfig, gp3 storage class, and OTel ConfigMap)
# is decoupled from Terraform apply to prevent state-lock conflicts and output lookup timing issues.
# Run 'bash terraform/scripts/post_apply.sh' immediately after 'terraform apply'.

module "lambda" {
  source = "./modules/lambda"

  enabled           = var.enable_health_check_lambda
  environment       = var.environment
  cluster_name      = var.cluster_name
  vote_health_url   = var.vote_health_url
  result_health_url = var.result_health_url
}
