# ---------------------------------------------------------------------------
# Variáveis da stack Finance Platform
# ---------------------------------------------------------------------------

variable "region" {
  description = "Região AWS onde a stack será implantada"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome do projeto — prefixo de todos os recursos"
  type        = string
  default     = "finance-platform"
}

variable "environment" {
  description = "Ambiente (dev/staging/prod) — usado em tags"
  type        = string
  default     = "dev"
}

variable "availability_zones" {
  description = "AZs usadas nas subnets públicas"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  description = "CIDR da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Imagens (GHCR) — tags parametrizadas por serviço
# ---------------------------------------------------------------------------

variable "authorization_image" {
  description = "Imagem GHCR do Authorization Service"
  type        = string
  default     = "ghcr.io/whoo-internet-co/authorization-service:latest"
}

variable "accounting_image" {
  description = "Imagem GHCR do Accounting Consumer"
  type        = string
  default     = "ghcr.io/whoo-internet-co/accounting-consumer:latest"
}

variable "fraud_image" {
  description = "Imagem GHCR do Fraud Consumer"
  type        = string
  default     = "ghcr.io/whoo-internet-co/fraud-consumer:latest"
}

variable "notification_image" {
  description = "Imagem GHCR do Notification Consumer"
  type        = string
  default     = "ghcr.io/whoo-internet-co/notification-consumer:latest"
}

# Para imagens GHCR privadas, informe o ARN do secret (Secrets Manager) com
# credenciais no formato {"username":"...","password":"..."}. Vazio = imagem pública.
variable "repository_credentials_secret_arn" {
  description = "ARN do secret (Secrets Manager) com credenciais GHCR (vazio = imagem pública)"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# ECS / Fargate
# ---------------------------------------------------------------------------

variable "authorization_port" {
  description = "Porta HTTP do container do Authorization Service (NestJS)"
  type        = number
  default     = 3000
}

variable "authorization_health_check_path" {
  description = "Path de health check do ALB para o Authorization Service"
  type        = string
  default     = "/health"
}

variable "authorization_desired_count" {
  description = "Número de tasks desejado do Authorization Service"
  type        = number
  default     = 1
}

variable "consumer_desired_count" {
  description = "Número de tasks desejado de cada consumer"
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "CPU (unidades, 1 vCPU = 1024) das task definitions Fargate"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memória (MB) das task definitions Fargate"
  type        = number
  default     = 512
}

# Nota: o graceful shutdown dos containers usa o stopTimeout default do
# Fargate (30s) — o provider Terraform não expõe o campo stopTimeout da task
# definition; SIGTERM é tratado pelos consumers (SqsConsumer.stop()).

# ---------------------------------------------------------------------------
# SQS / DLQ
# ---------------------------------------------------------------------------

variable "sqs_max_receive_count" {
  description = "maxReceiveCount do redrive policy (mensagens vão à DLQ após N recebimentos sem ACK)"
  type        = number
  default     = 5
}

variable "sqs_visibility_timeout" {
  description = "Visibility timeout (s) das filas de consumo"
  type        = number
  default     = 30
}

variable "sqs_receive_wait_time" {
  description = "Receive message wait time (s) — long polling"
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------

# Nomes das tabelas — convenção da plataforma (prefixo finance-platform).
# O .env.example do authorization-service usa defaults "authorization-service"/
# "authorization-service-checkpoint"; as task definitions ECS injetam estes
# valores via env (DYNAMODB_TABLE / DYNAMODB_CHECKPOINT_TABLE), sobrescrevendo
# os defaults do serviço. Ver terraform/README.md (divergências 1 e 3).
variable "authorization_table_name" {
  description = "Tabela single-table do Authorization Service (PK/SK + gsi-auth + Streams)"
  type        = string
  default     = "finance-platform-authorization"
}

variable "checkpoint_table_name" {
  description = "Tabela de checkpoint do relay in-process do Authorization Service (na AWS o relay é a Lambda)"
  type        = string
  default     = "finance-platform-authorization-checkpoint"
}

variable "accounting_entries_table_name" {
  description = "Ledger do Accounting Consumer (idempotente por event_id)"
  type        = string
  default     = "finance-platform-accounting-entries"
}

variable "consumer_idempotency_table_name" {
  description = "Deduplicação compartilhada dos consumers por event_id (ADR-007)"
  type        = string
  default     = "finance-platform-consumer-idempotency"
}

variable "dynamodb_billing_mode" {
  description = "Billing mode das tabelas DynamoDB"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "idempotency_ttl_days" {
  description = "TTL (dias) dos registros de idempotência"
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# CloudWatch
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Retenção dos log groups (dias)"
  type        = number
  default     = 7
}

variable "alarm_evaluation_periods" {
  description = "Períodos de avaliação dos alarmes (1 período = 5 min)"
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Lambda relay (outbox -> EventBridge)
# ---------------------------------------------------------------------------

variable "lambda_runtime" {
  description = "Runtime da Lambda relay de outbox"
  type        = string
  default     = "nodejs22.x"
}

variable "event_source_prefix" {
  description = "Source dos eventos publicados no EventBridge"
  type        = string
  default     = "co.whoo-internet.finance.authorization"
}

variable "event_detail_type" {
  description = "DetailType dos eventos no EventBridge"
  type        = string
  default     = "TransacaoAutorizada"
}