# Ambiente local — docker compose (LocalStack community)

Sobe a plataforma inteira em Docker com **LocalStack community**
(`dynamodb` + `sqs`), sem custo e sem conta AWS.

```
authorization-service ──TransactWriteItems──> DynamoDB single-table (LocalStack)
                                                    │ Streams (NEW_IMAGE)
                                                    ▼
                                          outbox-relay-local (Node 22)
                                                    │ fan-out direto (envelope c/ detail)
                        ┌───────────────────────────┼───────────────────────────┐
                        ▼                           ▼                           ▼
              SQS accounting-queue        SQS fraud-queue          SQS notification-queue
              (+DLQ, redrive=5)           (+DLQ, redrive=5)        (+DLQ, redrive=5)
                        ▼                           ▼                           ▼
              accounting-consumer         fraud-consumer           notification-consumer
```

> **Por que fan-out direto em vez de EventBridge?** O EventBridge é restrito
> ao **LocalStack Pro**. O ADR-006 autoriza explicitamente *adapter
> equivalente* para demonstração local: o `outbox-relay-local` lê o DynamoDB
> Streams da single-table, filtra INSERTs de outbox (`entity=OUTBOX`) e envia
> para as 3 filas o **mesmo envelope** que o EventBridge entregaria (payload
> de negócio em `detail`, `detail-type`/`source`/`time` no envelope),
> preservando o `event_id` para deduplicação (ADR-005/007). O parser dos
> consumers aceita flat **ou** envelope — o caminho de código testado é o
> mesmo da nuvem.

## Pré-requisitos

- Docker + Docker Compose v2
- (profile `build`) repos irmãos clonados em `../`: `authorization-service`,
  `accounting-consumer`, `fraud-consumer`, `notification-consumer`
- (profile `ghcr`) imagens publicadas em `ghcr.io/whoo-internet-co/*` e login:

```bash
# GHCR privado — usa o token do GitHub CLI (scope read:packages)
docker login ghcr.io -u <user> --password-stdin <<< $(gh auth token)
```

## Subindo

```bash
cd docker-compose
cp .env.example .env   # opcional (defaults já embutidos no compose)

# Infra + relay local (sem serviços de aplicação):
docker compose up -d --build

# Infra + authorization + 3 consumers via imagens GHCR:
docker compose --profile ghcr up -d --build

# Infra + authorization + 3 consumers via build local (repos irmãos):
docker compose --profile build up -d --build
```

Os profiles `ghcr` e `build` são **mutuamente exclusivos** (mesmos
container_name/porta). O init do LocalStack (`init/init-localstack.sh`) roda
automaticamente no boot e cria:

- tabelas: `finance-platform-authorization` (PK/SK + `gsi-auth` + TTL `ttl` +
  Streams NEW_IMAGE), `finance-platform-authorization-checkpoint`,
  `finance-platform-accounting-entries`, `finance-platform-consumer-idempotency`
  (TTL `expires_at`);
- filas: `finance-platform-{accounting,fraud,notification}-queue` + DLQs com
  redrive `maxReceiveCount=5`.

## Seed + teste rápido

```bash
# Seed de contrato com limite (shape idêntico ao buildContractItem do serviço)
./scripts/seed-contract.sh CTR-DEMO-001 1000 BRL

# Autorização (201) — o roteiro completo está em ../demo-script.md
curl -i -X POST "http://localhost:3000/v1/contratos/CTR-DEMO-001/autorizacoes" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"id_conta":"ACC-001","valor":100.00,"moeda":"BRL","tipo_operacao":"DEBITO"}'

# Ver o evento relayado e consumido
docker compose logs -f outbox-relay-local
docker compose --profile ghcr logs -f fraud-consumer notification-consumer accounting-consumer
```

## Healthchecks / troubleshooting

| Serviço              | Healthcheck                       | Observações                                    |
| -------------------- | --------------------------------- | ---------------------------------------------- |
| localstack           | `GET /_localstack/health`         | init roda no hook `ready.d`                     |
| authorization-*      | `GET http://localhost:3000/health`| exige adapter HTTP do serviço (repo em paralelo)|
| consumers / relay    | `pidof node`                      | processos de background (sem porta)             |

- `docker compose ps` — status/health de tudo.
- Relay sem eventos: confirme `docker compose logs outbox-relay-local` →
  `table ready` e que a autorização gravou item `OUTBOX#...` (a single-table
  gera INSERTs de contrato/idempotência que o relay **ignora** por design).
- Reiniciar limpo: `docker compose down -v` (remove o volume do LocalStack).

## Divergências assumidas vs. stack AWS

1. **Sem EventBridge** (LocalStack Pro) → fan-out direto do relay para as 3
   filas, envelope idêntico (ADR-006 autoriza adapter equivalente).
2. **Sem ALB** → authorization exposto direto em `localhost:3000`.
3. `RELAY_PUBLISHER=none` no authorization-service: quem relê o outbox é o
   `outbox-relay-local` (streams), não o publisher in-process do serviço.
4. `accounting-consumer` em desenvolvimento paralelo: o profile `build` exige
   `../accounting-consumer` com Dockerfile; o profile `ghcr` exige a imagem
   publicada. Até lá, o compose sobe infra+relay e os demais consumers.
5. Idempotência dos consumers fraud/notification é **in-memory** nos repos
   atuais (dedup perdida em restart) — na AWS o accounting usará backend
   DynamoDB (`IDEMPOTENCY_BACKEND=dynamodb`, já configurado no compose).
