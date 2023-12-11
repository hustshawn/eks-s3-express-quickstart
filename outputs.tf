output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "vpc_private_subnets" {
  value = module.vpc.private_subnets
}

output "s3_express_az_id" {
  value = data.aws_availability_zones.available.zone_ids[index(data.aws_availability_zones.available.names, local.s3_express_az)]
}

output "s3_express_bucket" {
  value = aws_s3_directory_bucket.express_bucket.bucket
}
