provider "aws" {
  region = local.region
  # Comment out the 'endpoints' section when creating the s3-express bucket; then uncomment it when reading the s3-express bucket
  endpoints {
    s3 = "s3-accesspoint.${local.region}.amazonaws.com"
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

locals {
  name            = "s3-csi-demo"
  cluster_version = "1.27"
  region          = "us-east-1"

  s3_express_az    = "us-east-1b"
  s3_express_az_id = data.aws_availability_zones.available.zone_ids[index(data.aws_availability_zones.available.names, local.s3_express_az)]

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-modules"
  }
}


################################################################################
# EKS Module
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.18"

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true

  # I want to disable the cluster encryption at rest
  cluster_encryption_config = {}

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-mountpoint-s3-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.aws_mountpoint_s3_csi_driver_irsa.iam_role_arn
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  manage_aws_auth_configmap = true

  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    instance_types = ["m6i.large", "m5.large", "m5n.large", "m5zn.large"]
    capacity_type  = "SPOT"
    # We are using the IRSA created below for permissions
    # However, we have to deploy with the policy attached FIRST (when creating a fresh cluster)
    # and then turn this off after the cluster/node group is created. Without this initial policy,
    # the VPC CNI fails to assign IPs and nodes cannot join the cluster
    # See https://github.com/aws/containers-roadmap/issues/1666 for more context
    iam_role_attach_cni_policy = true
  }

  eks_managed_node_groups = {
    s3_express_app_ng = {
      use_custom_launch_template = false
      disk_size                  = 50
      min_size                   = 1
      max_size                   = 2
      desired_size               = 1
      subnet_ids                 = [module.vpc.private_subnets[index(module.vpc.azs, local.s3_express_az)]]
    }
  }

  tags = local.tags
}


################################################################################
# s3-csi-driver IRSA
################################################################################
module "aws_mountpoint_s3_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-s3-csi-driver-"
  role_policy_arns = {
    s3_full_access    = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
    s3_express_access = resource.aws_iam_policy.s3_express_access.arn
  }
  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "kube-system:s3-csi-driver-sa"
      ]
    }
  }
  tags = local.tags
}
data "aws_iam_policy_document" "s3_express_access" {
  statement {
    effect = "Allow"
    actions = [
      "s3express:CreateSession",
    ]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "s3_express_access" {
  name        = "${module.eks.cluster_name}-s3-express-access"
  description = "Allows access to S3 Express"
  policy      = data.aws_iam_policy_document.s3_express_access.json
}


################################################################################
# S3 Express Bucket
################################################################################
resource "aws_s3_directory_bucket" "express_bucket" {
  # S3 directory bucket names must follow the format
  # <User chosen prefix>--<AZ ID>--x-s3
  # where <AZ ID> is the Availability Zone ID
  # 	https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html#az-ids
  # You can use the aws_availability_zone data source to obtain the AZ ID.
  bucket = "s3-express-${local.s3_express_az}--${local.s3_express_az_id}--x-s3"
  location {
    name = local.s3_express_az_id
  }
  # All objects should be deleted from the bucket when the bucket is destroyed
  # so that the bucket can be destroyed without error.
  force_destroy = true
}

################################################################################
# S3 Express App
################################################################################
data "kubectl_path_documents" "s3_express_app" {
  pattern = "${path.module}/k8s-templates/*.yaml"
  vars = {
    size   = "1200Gi"
    az     = local.s3_express_az
    region = local.region
    bucket = aws_s3_directory_bucket.express_bucket.bucket
  }
}

resource "kubectl_manifest" "s3_express_app" {
  for_each  = toset(data.kubectl_path_documents.s3_express_app.documents)
  yaml_body = each.value
}

################################################################################
# Supporting Resources
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Tags subnets for Karpenter auto-discovery
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
