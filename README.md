# Finance Platform — entrega POD99 (AWS/Itaú)

Meta-repo agregador da plataforma de **autorização de transações financeiras**.
A implementação vive em 6 repositórios da org GitHub [`Whoo-Internet-co`](https://github.com/Whoo-Internet-co); este repositório concentra documentação, ADRs, diagramas, docker-compose local e Terraform.

## Visão

```text
Cliente → ALB → authorization-service (NestJS) → DynamoDB single-table
                                                    │ Outbox + Streams
                                                    ▼
                                              Outbox Relay
                                                    │ EventBridge (AWS) / fan-out SQS (local)
                        ┌───────────────────────────┼───────────────────────────┐
                        ▼                           ▼                           ▼
              accounting-consumer         fraud-consumer           notification-consumer
```

- Reserva atômica de limite + `Idempotency-Key` (ADR-003/004)
- Evento `TransacaoAutorizada` v1 via package de contratos (ADR-008)
- Consumers at-least-once com dedup por `event_id` (ADR-007)

## Mapa dos repositórios

| Repo | Papel |
| --- | --- |
| [finance-platform-contracts](https://github.com/Whoo-Internet-co/finance-platform-contracts) | OpenAPI + JSON Schema + package npm `@whoo-internet-co/finance-platform-contracts` |
| [authorization-service](https://github.com/Whoo-Internet-co/authorization-service) | Core síncrono: POST autorizações, outbox, relay |
| [accounting-consumer](https://github.com/Whoo-Internet-co/accounting-consumer) | Ledger real (idempotente) |
| [fraud-consumer](https://github.com/Whoo-Internet-co/fraud-consumer) | Antifraude mock |
| [notification-consumer](https://github.com/Whoo-Internet-co/notification-consumer) | Notificação mock |
| [finance-platform](https://github.com/Whoo-Internet-co/finance-platform) (este) | Docs, compose, Terraform |

Imagens GHCR (lowercase): `ghcr.io/whoo-internet-co/{authorization-service,accounting-consumer,fraud-consumer,notification-consumer}`.

## Como rodar a demo local

```bash
cd docker-compose
# Ver docker-compose/README.md — LocalStack (dynamodb+sqs) + services
docker compose up --build
```

Depois execute o roteiro em [`demo-script.md`](demo-script.md) (201/200/402/409/422, concorrência, dedup, outbox→consumers).

## Validar Terraform

```bash
cd terraform
terraform fmt -check
terraform init -backend=false
terraform validate
```

Guia completo: [`docs/deployment.md`](docs/deployment.md).

## Documentação

Índice em [`docs/README.md`](docs/README.md) — architecture, deployment, diagramas C4, ADRs 001–008.

## Definition of Done

| Área | Item | Status |
| --- | --- | --- |
| CORE | POST autorizações 201/200/402/409/422 + Idempotency-Key + reserva atômica + concorrência | ✅ |
| ARCHITECTURE | Clean/Hexagonal, domain sem AWS, ports/adapters | ✅ |
| EVENTS | TransacaoAutorizada v1, Outbox, EventBridge/SQS+DLQ, idempotência consumers | ✅ |
| CONSUMERS | accounting (real), fraud (mock), notification (mock) | ✅ |
| QUALITY | unit+integration, coverage ≥80% core, lint/build, sem skips | ✅ |
| DELIVERY | Dockerfiles, compose, Actions, GHCR, terraform validate, OpenAPI, ADRs, README, demo | ✅ |

## Escopo congelado (não implementar)

Cognito real, EKS, Kinesis, service mesh, antifraude real, multi-region.
