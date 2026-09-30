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

  cluster_name        = var.cluster_name
  cluster_version     = var.cluster_version
  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}

# Automatically runs post-apply configuration (kubeconfig update, gp3 storage class, and app deploy)
resource "null_resource" "cluster_auto_setup" {
  depends_on = [module.eks]

  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/post_apply.sh"
    environment = {
      AWS_REGION   = var.aws_region
      CLUSTER_NAME = module.eks.cluster_name
    }
  }
}
