# Votex Terraform Remote State Bootstrap

This module provisions an independent, secure Amazon S3 bucket for storing Terraform remote state with **native S3 lockfile state locking** (`use_lockfile = true`), completely eliminating DynamoDB.

## Architecture

- **S3 Bucket**: Versioned, encrypted (AES256), with full public access block.
- **Native State Locking**: Terraform 1.10+ uses native S3 conditional writes (`.tflock` objects). No DynamoDB table or IAM permissions required.
- **Decoupled Architecture**: Prevents circular dependencies by ensuring the backend bucket exists before the main EKS cluster stack initializes.

## Usage (Run Once Before EKS Deployment)

```bash
cd terraform/bootstrap

# 1. Initialize bootstrap
terraform init

# 2. Plan and apply (specify a unique bucket name)
terraform plan -var="state_bucket_name=votex-tfstate-<YOUR_AWS_ACCOUNT_ID>-eu-north-1"
terraform apply -var="state_bucket_name=votex-tfstate-<YOUR_AWS_ACCOUNT_ID>-eu-north-1"

# 3. Capture bucket name output
terraform output -raw state_bucket_name
```

## Initializing Main Stack with S3 Backend

```bash
cd ../

# 1. Activate backend configuration
cp backend.tf.example backend.tf

# 2. Initialize and migrate state into S3
terraform init -backend-config="bucket=<STATE_BUCKET_NAME>" -migrate-state
```

