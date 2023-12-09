S3 Express One Zone with Amazon EKS demo
===
This repo is to demonstrate the usage for S3 Express One Zone usage with Mountpoint for Amazon S3 CSI Driver on EKS. 

## Prequisite
1. AWS credentials setup on your workstation. Prefer admin equivalent for less friction.
2. Terraform installed.

## Setup
Initalize the project
```
terrafrom init
terraform plan -out planfile
```

Deploy
```
terraform apply "planfile"
```

Once deployed, you will have an EKS cluster running, with default demo application being deployed and mount the S3 Directory Bucket (bucket with S3 Express One Zone storage class).