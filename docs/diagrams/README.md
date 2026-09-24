# Diagramas — Finance Platform

Diagramas Mermaid (renderizam nativamente no GitHub/VS Code).

| Diagrama                                        | Nível / tipo            | Conteúdo                                                            |
| ------------------------------------------------ | ----------------------- | -------------------------------------------------------------------- |
| [c4-context.md](./c4-context.md)                 | C4 Contexto             | usuários, plataforma e sistemas externos                             |
| [c4-container.md](./c4-container.md)             | C4 Container            | serviços, stores, brokers + equivalências do ambiente local          |
| [sequence-authorization.md](./sequence-authorization.md) | Sequência       | idempotency acquire → TransactWriteItems [limite+auth+idempotency+outbox] → Streams → relay → EventBridge → SQS → consumers idempotentes |
| [deployment-aws.md](./deployment-aws.md)         | Deploy (físico)         | VPC/AZs, ECS, ALB, DynamoDB, Lambda, EventBridge, SQS/DLQ, CloudWatch |

Fontes de verdade: ADRs 001–008, `finance-platform-contracts`
(OpenAPI v1 + `TransacaoAutorizada` v1) e código dos serviços.
