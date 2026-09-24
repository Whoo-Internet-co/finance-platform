#!/bin/bash
# ---------------------------------------------------------------------------
# Init LocalStack (hook ready.d) — cria tabelas e filas idênticas às da stack
# Terraform (nomes, chaves, GSI, TTL, streams, redrive).
# Idempotente: ResourceInUse / QueueAlreadyExists são ignorados.
# ---------------------------------------------------------------------------
set -uo pipefail

echo "[init] Criando tabelas DynamoDB..."

PREFIX="${QUEUE_PREFIX:-finance-platform}"
AUTH_TABLE="${AUTHORIZATION_TABLE:-finance-platform-authorization}"
CKPT_TABLE="${CHECKPOINT_TABLE:-finance-platform-authorization-checkpoint}"
ENTRIES_TABLE="${ACCOUNTING_ENTRIES_TABLE:-finance-platform-accounting-entries}"
IDEM_TABLE="${CONSUMER_IDEMPOTENCY_TABLE:-finance-platform-consumer-idempotency}"

ignore_exists() {
  # Executa comando; se falhar por "já existe", segue; senão propaga erro.
  local out
  set +e
  out=$("$@" 2>&1)
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if echo "$out" | grep -qE 'ResourceInUseException|QueueAlreadyExists|QueueNameExists|Cannot create preexisting'; then
    echo "[init] já existe (ok): $*"
    return 0
  fi
  echo "$out" >&2
  return "$rc"
}

set -e

# Single-table do authorization-service (PK/SK + gsi-auth + Streams NEW_IMAGE).
ignore_exists awslocal dynamodb create-table \
  --table-name "$AUTH_TABLE" \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
    AttributeName=gsi1_pk,AttributeType=S \
    AttributeName=gsi1_sk,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{"IndexName":"gsi-auth","KeySchema":[{"AttributeName":"gsi1_pk","KeyType":"HASH"},{"AttributeName":"gsi1_sk","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_IMAGE

awslocal dynamodb update-time-to-live \
  --table-name "$AUTH_TABLE" \
  --time-to-live-specification "Enabled=true,AttributeName=ttl" >/dev/null || true

ignore_exists awslocal dynamodb create-table \
  --table-name "$CKPT_TABLE" \
  --attribute-definitions AttributeName=PK,AttributeType=S AttributeName=SK,AttributeType=S \
  --key-schema AttributeName=PK,KeyType=HASH AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

ignore_exists awslocal dynamodb create-table \
  --table-name "$ENTRIES_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

ignore_exists awslocal dynamodb create-table \
  --table-name "$IDEM_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

awslocal dynamodb update-time-to-live \
  --table-name "$IDEM_TABLE" \
  --time-to-live-specification "Enabled=true,AttributeName=expires_at" >/dev/null || true

echo "[init] Criando filas SQS (3 consumers + 3 DLQs, redrive maxReceiveCount=5)..."

for svc in accounting fraud notification; do
  ignore_exists awslocal sqs create-queue --queue-name "${PREFIX}-${svc}-queue-dlq"
  DLQ_URL=$(awslocal sqs get-queue-url --queue-name "${PREFIX}-${svc}-queue-dlq" \
    --query QueueUrl --output text)
  DLQ_ARN=$(awslocal sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

  ignore_exists awslocal sqs create-queue --queue-name "${PREFIX}-${svc}-queue" \
    --attributes "{\"VisibilityTimeout\":\"30\",\"ReceiveMessageWaitTimeSeconds\":\"5\",\"MessageRetentionPeriod\":\"1209600\",\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"5\\\"}\"}"

  echo "[init] fila ${PREFIX}-${svc}-queue -> DLQ ${PREFIX}-${svc}-queue-dlq"
done

echo "[init] Pronto. Tabelas: $AUTH_TABLE, $CKPT_TABLE, $ENTRIES_TABLE, $IDEM_TABLE"
echo "[init] Filas: ${PREFIX}-{accounting,fraud,notification}-queue (+DLQs)"
