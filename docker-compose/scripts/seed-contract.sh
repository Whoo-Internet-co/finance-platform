#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Seed de contrato/limite no LocalStack (single-table do authorization-service).
#
# Uso:
#   ./scripts/seed-contract.sh [ID_CONTRATO] [LIMITE_TOTAL] [MOEDA]
#   ./scripts/seed-contract.sh CTR-DEMO-001 1000 BRL
#
# Item gravado (shape idêntico a buildContractItem em DynamoDbTable.ts):
#   PK=CONTRACT#<id>  SK=PROFILE#<id>  entity=CONTRATO
#   available_limit=total_limit=<limite>  ativo=true
# ---------------------------------------------------------------------------
set -euo pipefail

ID_CONTRATO="${1:-CTR-DEMO-001}"
LIMITE="${2:-1000}"
MOEDA="${3:-BRL}"
ENDPOINT_URL="${ENDPOINT_URL:-http://localhost:4566}"
TABLE="${AUTHORIZATION_TABLE:-finance-platform-authorization}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# LocalStack não valida credenciais, mas o AWS CLI exige algo definido.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

aws --endpoint-url "$ENDPOINT_URL" dynamodb put-item \
  --table-name "$TABLE" \
  --item "{
    \"PK\":              {\"S\": \"CONTRACT#${ID_CONTRATO}\"},
    \"SK\":              {\"S\": \"PROFILE#${ID_CONTRATO}\"},
    \"entity\":          {\"S\": \"CONTRATO\"},
    \"id_contrato\":     {\"S\": \"${ID_CONTRATO}\"},
    \"available_limit\": {\"N\": \"${LIMITE}\"},
    \"total_limit\":     {\"N\": \"${LIMITE}\"},
    \"moeda\":           {\"S\": \"${MOEDA}\"},
    \"ativo\":           {\"BOOL\": true},
    \"updated_at\":      {\"S\": \"${NOW}\"}
  }"

echo "Contrato ${ID_CONTRATO} criado: limite total/disponível = ${LIMITE} ${MOEDA} (tabela ${TABLE})"
