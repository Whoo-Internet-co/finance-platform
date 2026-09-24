# ---------------------------------------------------------------------------
# Finance Platform — POD99 (desafio técnico AWS/Itaú)
# Meta-repo de entrega — stack representativa e implantável (custo mínimo).
#
# Módulo raiz: provê a infraestrutura da plataforma:
#   ECS/Fargate (authorization + 3 consumers) | ALB | DynamoDB + Streams
#   Lambda outbox relay (DynamoDB Streams -> EventBridge)
#   EventBridge -> SQS fan-out (3 filas + 3 DLQs) | IAM | CloudWatch
#
# Decisões e justificativas: ver terraform/README.md
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Backend remoto OPCIONAL — habilite ao operar com equipe/CI.
  # Crie o bucket e a tabela de lock antes de descomentar:
  #   aws s3api create-bucket --bucket finance-platform-tfstate --region us-east-1
  #   aws dynamodb create-table --table-name finance-platform-tfstate-locks \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST
  #
  # backend "s3" {
  #   bucket         = "finance-platform-tfstate"
  #   key            = "finance-platform/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "finance-platform-tfstate-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region
  # Tags default em todos os recursos (AWS provider >= 4.67)
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}