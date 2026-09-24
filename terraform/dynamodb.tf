# ---------------------------------------------------------------------------
# DynamoDB — modelagem orientada a access patterns (ADR-003/004/006).
#
# ALINHADO COM O AUTHORIZATION-SERVICE REAL (single-table, ver
# src/adapters/outbound/dynamodb/DynamoDbTable.ts no repo do serviço):
#
#   authorization-service  -> UMA tabela single-table:
#                              PK=`CONTRACT#id`  SK=`PROFILE#id`        (contrato/limite)
#                              PK=`CONTRACT#id`  SK=`AUTH#id_autorizacao`
#                              PK=`IDEMPOTENCY#chave` SK=igual          (TTL `ttl`)
#                              PK=`OUTBOX#event_id`  SK=igual          (Streams -> relay)
#                            GSI `gsi-auth` (gsi1_pk/gsi1_sk = id_autorizacao)
#                            StreamViewType=NEW_IMAGE (ADR-006)
#   authorization-service-checkpoint -> tabela de checkpoint do relay sidecar
#                            (reservada; na stack Fargate o checkpointing do
#                            stream é feito pelo event source mapping da Lambda).
#
# Tabelas dos consumers:
#   finance-platform-accounting-entries   -> ledger do Accounting Consumer
#   finance-platform-consumer-idempotency -> deduplicação por event_id (ADR-007);
#                                            usada pelo accounting (backend=dynamodb).
# ---------------------------------------------------------------------------

# Tabela principal single-table do Authorization Service.
resource "aws_dynamodb_table" "authorization" {
  name         = var.authorization_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "gsi1_pk"
    type = "S"
  }

  attribute {
    name = "gsi1_sk"
    type = "S"
  }

  global_secondary_index {
    name            = "gsi-auth"
    hash_key        = "gsi1_pk"
    range_key       = "gsi1_sk"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl" # ADR-004: expiração de chaves de idempotência
    enabled        = true
  }

  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  point_in_time_recovery {
    enabled = false
  }

  tags = { Name = var.authorization_table_name }
}

# Tabela de checkpoint do relay sidecar (usada se o serviço rodar o próprio
# relay). Na stack principal, o relay é a Lambda (DynamoDB Streams -> EventBridge).
resource "aws_dynamodb_table" "authorization_checkpoint" {
  name         = var.checkpoint_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery {
    enabled = false
  }

  tags = { Name = var.checkpoint_table_name }
}

# Ledger do Accounting Consumer (criado em paralelo).
resource "aws_dynamodb_table" "accounting_entries" {
  name         = var.accounting_entries_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = false
  }

  tags = { Name = var.accounting_entries_table_name }
}

# Idempotência compartilhada dos consumers (deduplicação por event_id).
resource "aws_dynamodb_table" "consumer_idempotency" {
  name         = var.consumer_idempotency_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }

  tags = { Name = var.consumer_idempotency_table_name }
}