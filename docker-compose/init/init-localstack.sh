#!/bin/bash
# ---------------------------------------------------------------------------
# Init LocalStack (hook ready.d) — cria tabelas e filas idênticas às da stack
# Terraform (nomes, chaves, GSI, TTL, streams, redrive).
# Executado automaticamente quando o LocalStack fica ready.
# ---------------------------------------------------------------------------
set -euo pipefail

echo "[init] Criando tabelas DynamoDB..."

PREFIX="${QUEUE_PREFIX:-finance-platform}"
AUTH_TABLE="${AUTHORIZATION_TABLE:-finance-platform-authorization}"
CKPT_TABLE="${CHECKPOINT_TABLE:-finance-platform-authorization-checkpoint}"
ENTRIES_TABLE="${ACCOUNTING_ENTRIES_TABLE:-finance-platform-accounting-entries}"
IDEM_TABLE="${CONSUMER_IDEMPOTENCY_TABLE:-finance-platform-consumer-idempotency}"

# Single-table do authorization-service (PK/SK + gsi-auth + Streams NEW_IMAGE),
# idêntica a terraform/dynamodb.tf.
awslocal dynamodb create-table \
  --table-name "$AUTH_TABLE" \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
    AttributeName=gsi1_pk,AttributeType=S \
    AttributeName=gsi1_sk,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes "[
    {
      \"Name\": \"gsi-auth\",
      \"KeySchema\": [
        {\"AttributeName\": \"gsi1_pk\", \"KeyType\": \"HASH\"},
        {\"AttributeName\": \"gsi1_sk\", \"KeyType\": \"RANGE\"}
      ],
      \"Projection\": {\"ProjectionType\": \"ALL\"}
    }
  ]" \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE

awslocal dynamodb update-time-to-live \
  --table-name "$AUTH_TABLE" \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"

# Checkpoint do relay in-process (compatibilidade; o relay local usa Streams).
awslocal dynamodb create-table \
  --table-name "$CKPT_TABLE" \
  --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

# Ledger do accounting-consumer (idempotente por event_id).
awslocal dynamodb create-table \
  --table-name "$ENTRIES_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Idempotência compartilhada dos consumers (dedup por event_id, TTL expires_at).
awslocal dynamodb create-table \
  --table-name "$IDEM_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

awslocal dynamodb update-time-to-live \
  --table-name "$IDEM_TABLE" \
  --time-to-live-specification "Enabled=true,AttributeName=expires_at"

echo "[init] Criando filas SQS (3 consumers + 3 DLQs, redrive maxReceiveCount=5)..."

for svc in accounting fraud notification; do
  DLQ_ARN=$(awslocal sqs create-queue --queue-name "${PREFIX}-${svc}-queue-dlq" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['QueueUrl'])" \
    | xargs -I{} awslocal sqs get-queue-attributes --queue-url {} --attribute-name-All \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['Attributes']['QueueArn'])")

  awslocal sqs create-queue --queue-name "${PREFIX}-${svc}-queue" \
    --attributes "{
      \"VisibilityTimeout\": \"30\",
      \"ReceiveMessageWaitTimeSeconds\": \"5\",
      \"MessageRetentionPeriod\": \"1209600\",
      \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\": \\\"${DLQ_ARN}\\\", \\\"maxReceiveCount\\\": \\\"5\\\"}\"
    }" >/dev/null

  echo "[init] fila ${PREFIX}-${svc}-queue -> DLQ ${PREFIX}-${svc}-queue-dlq"
done

echo "[init] Pronto. Tabelas: $AUTH_TABLE, $CKPT_TABLE, $ENTRIES_TABLE, $IDEM_TABLE"
echo "[init] Filas: ${PREFIX}-{accounting,fraud,notification}-queue (+DLQs)"
