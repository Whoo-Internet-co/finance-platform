# Demo Script — Finance Platform

Roteiro ponta a ponta da plataforma: API de autorização (idempotência +
limite) → outbox → relay → filas → consumers idempotentes.

**Ambiente**: docker-compose local (default) — `BASE_URL=http://localhost:3000`.
Na AWS, troque por `BASE_URL=http://$(terraform -chdir=terraform output -raw alb_dns_name)`.

> ⚠️ **Pendências marcadas com 🔶** — dependem dos repos finalizados em
> paralelo (`authorization-service`, `accounting-consumer`) e da publicação
> das imagens GHCR. Ver resumo no final.

## 0. Subir o ambiente

```bash
cd docker-compose
docker compose --profile ghcr up -d --build    # ou --profile build
docker compose ps                               # tudo healthy?
./scripts/seed-contract.sh CTR-DEMO-001 1000 BRL   # seed do contrato/limite
```

🔶 *Pendente: imagens GHCR publicadas; adapter HTTP do authorization-service
(finalização em paralelo). Sem imagem, valide a infra com
`docker compose up -d` (localstack + relay) e o seed com awscli.*

```bash
export BASE_URL=http://localhost:3000
export CONTRATO=CTR-DEMO-001
```

## 1. Happy path — POST → `201 Created`

```bash
KEY1=$(uuidgen)
curl -si -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $KEY1" \
  -d '{"id_conta":"ACC-001","valor":100.00,"moeda":"BRL","tipo_operacao":"DEBITO","id_estabelecimento":"EST-123"}'
```

**Esperado**: `201` + header `Location` + body `AutorizacaoResponse`
(`status: APROVADA`, `saldo_reservado: 900`).

Verifique o outbox relé e o fan-out:

```bash
docker compose logs outbox-relay-local | grep relayed        # event_id preservado
aws --endpoint-url http://localhost:4566 dynamodb scan \
  --table-name finance-platform-accounting-entries --query 'Count'   # ledger (🔶 accounting-consumer)
```

## 2. Replay idempotente — mesma chave → `200`

```bash
curl -si -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $KEY1" \
  -d '{"id_conta":"ACC-001","valor":100.00,"moeda":"BRL","tipo_operacao":"DEBITO","id_estabelecimento":"EST-123"}'
```

**Esperado**: `200` + **mesmo** `id_autorizacao` do passo 1 + header
`Idempotency-Key` ecoado. Limite **não** é debitado de novo
(`saldo_reservado: 900` permanece).

## 3. Limite excedido → `402 Payment Required`

```bash
curl -si -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"id_conta":"ACC-001","valor":950.00,"moeda":"BRL","tipo_operacao":"DEBITO"}'
```

**Esperado**: `402` + `application/problem+json` (RFC 7807,
`type: .../problems/limite-insuficiente`). Disponível = 900 < 950.
Recusa determinística fica persistida (replay da MESMA chave → mesmo 402).

## 4. Chave reutilizada com payload divergente → `409 Conflict`

```bash
curl -si -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $KEY1" \
  -d '{"id_conta":"ACC-001","valor":50.00,"moeda":"BRL","tipo_operacao":"CREDITO"}'
```

**Esperado**: `409` + problem+json — a chave `$KEY1` já foi processada com
**outro** request_hash (ADR-004: chave é comprometida com o payload).

## 5. Payload inválido → `422 Unprocessable Entity`

```bash
# valor <= 0 (exclusiveMinimum no OpenAPI) e moeda inválida
curl -si -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"id_conta":"ACC-001","valor":-10,"moeda":"XXX","tipo_operacao":"DEBITO"}'

# campo desconhecido (additionalProperties: false)
curl -si -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"id_conta":"ACC-001","valor":10,"moeda":"BRL","tipo_operacao":"DEBITO","hack":true}'
```

**Esperado**: `422` + problem+json com `errors[]` por campo.

## 6. Concorrência — 2 requisições simultâneas, mesma chave

```bash
KEY2=$(uuidgen)
PAYLOAD='{"id_conta":"ACC-002","valor":25.00,"moeda":"BRL","tipo_operacao":"RESERVA"}'
for i in 1 2; do
  curl -s -o /tmp/conc-$i.out -w "req$i -> HTTP %{http_code}\n" \
    -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
    -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY2" -d "$PAYLOAD" &
done; wait
cat /tmp/conc-1.out /tmp/conc-2.out
```

**Esperado**: exatamente **um** `201`; o outro `200` (se chegou após a
conclusão) **ou** `409 concorrência` (se chegou com a chave ainda
`EM_ANDAMENTO`). Nunca dois `201` — o `acquire` é conditional write atômico.
Limite debitado **uma única vez**.

## 7. Consumers — processamento e dedup por `event_id`

```bash
# Logs dos 3 consumers (processaram o evento do passo 1)
docker compose --profile ghcr logs fraud-consumer | grep -i transacao
docker compose --profile ghcr logs notification-consumer | grep -i transacao
docker compose --profile ghcr logs accounting-consumer | grep -i entry   # 🔶

# Dedup: re-entrega manual do MESMO evento (simula retry at-least-once).
# Pegue o envelope relayado e reenvie à fila do fraud:
EVENT_JSON=$(aws --endpoint-url http://localhost:4566 sqs receive-message \
  --queue-url http://localhost:4566/000000000000/finance-platform-fraud-queue \
  --max-number-of-messages 1 --wait-time-seconds 0 || true)
# Com a fila vazia (consumer já consumiu), duplique via novo POST + reenvio:
KEY3=$(uuidgen)
curl -s -X POST "$BASE_URL/v1/contratos/$CONTRATO/autorizacoes" \
  -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY3" \
  -d '{"id_conta":"ACC-003","valor":10.00,"moeda":"BRL","tipo_operacao":"DEBITO"}' >/dev/null
sleep 2
# O relay publica 1× por INSERT de outbox; para forçar duplicata, repita a
# mensagem na fila com o MESMO event_id do corpo recebido nos logs:
#   aws --endpoint-url http://localhost:4566 sqs send-message \
#     --queue-url http://localhost:4566/000000000000/finance-platform-fraud-queue \
#     --message-body '<envelope copiado do log do relay>'
docker compose --profile ghcr logs --since 2m fraud-consumer | grep -iE "duplicate|dedup|already"
```

**Esperado**: na duplicata, o consumer loga **duplicate/skip** (dedup por
`event_id`) e faz ACK (`DeleteMessage`) **sem** efeito colateral repetido.

🔶 *Pendente: fraud/notification usam `InMemoryIdempotencyRepository` hoje —
dedup válida por processo; restart perde o histórico. accounting usará backend
DynamoDB (`IDEMPOTENCY_BACKEND=dynamodb`), durável.*

## 8. DLQ (opcional)

```bash
# Mensagem inválida direto na fila → consumer não faz ACK → DLQ após 5 tentativas
aws --endpoint-url http://localhost:4566 sqs send-message \
  --queue-url http://localhost:4566/000000000000/finance-platform-fraud-queue \
  --message-body '{"detail":{"event_id":"invalido"}}'
sleep 200   # 5 × visibility 30s
aws --endpoint-url http://localhost:4566 sqs get-queue-attributes \
  --queue-url http://localhost:4566/000000000000/finance-platform-fraud-queue-dlq \
  --attribute-names ApproximateNumberOfMessages
```

**Esperado**: DLQ com 1 mensagem (na AWS: alarme `fraud-dlq-depth` dispara).

## 9. Teardown

```bash
docker compose down -v   # local
# terraform -chdir=terraform destroy   # AWS
```

---

## Resumo de pendências (🔶)

| # | Pendência | Impacto na demo | Desbloqueio |
| - | --------- | --------------- | ----------- |
| 1 | Adapter HTTP do authorization-service em finalização (repo paralelo) | passos 1–6 exigem o serviço no ar | merge do inbound HTTP + Dockerfile no repo do serviço |
| 2 | Imagens GHCR não publicadas | profiles `ghcr` sem imagem | publicar via workflow dos repos (login: `docker login ghcr.io -u <user> --password-stdin <<< $(gh auth token)`) |
| 3 | `accounting-consumer` em desenvolvimento (repo vazio) | passo 1 (ledger) e passo 7 (dedup dynamodb) parciais | baselines na main do repo + imagem |
| 4 | fraud/notification com dedup in-memory | passo 7 perde dedup após restart | backend dynamodb opcional nos consumers (já provisionado: tabela `finance-platform-consumer-idempotency`) |
| 5 | AWS: sem credenciais `[default]` válidas nesta máquina | demo AWS só após `AWS_PROFILE=<profile>` | configurar profile (ver terraform/README.md) |
