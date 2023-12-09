terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.29.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.14.0"
    }
    # kubectl = {
    #   source  = "alekc/kubectl"
    #   version = ">= 2.0.2"
    # }
  }
}
