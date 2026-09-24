# Documentação — Finance Platform

Índice geral da documentação do meta-repo de entrega.

## Guias

| Documento | Conteúdo |
| --------- | -------- |
| [architecture.md](architecture.md) | Desenho ponta a ponta: contexto de negócio (autorização de transações, ~5k TPS pico, 80M contas), bounded contexts, fluxo síncrono (ALB → authorization-service → `TransactWriteItems` com limite+autorização+idempotência+outbox), fluxo assíncrono (Streams → relay → EventBridge → SQS → consumers idempotentes), resiliência e trade-offs (Fargate vs Lambda, DynamoDB vs Aurora, EventBridge vs SNS/Kinesis/MSK, outbox vs dual write) |
| [deployment.md](deployment.md) | Deploy AWS: pré-requisitos, variáveis do Terraform, `init`/`plan`/`apply`, verificação e smoke test, `destroy`, custos (~US$ 1,20–1,50/dia na stack mínima — destruir após a demo) e imagens GHCR privadas (espelho ECR vs `repository_credentials` com PAT) |
| [../demo-script.md](../demo-script.md) | Roteiro de demo ponta a ponta (curl): seed de contrato, `201`, replay `200`, `402`, `409` (chave/payload divergente), `422`, concorrência com 2 simultâneos, dedup por `event_id` nos consumers, DLQ e teardown |

## Diagramas — [diagrams/](diagrams/)

| Diagrama | Nível |
| -------- | ----- |
| [c4-context.md](diagrams/c4-context.md) | C4 nível 1 — atores, plataforma e sistemas externos |
| [c4-container.md](diagrams/c4-container.md) | C4 nível 2 — serviços, stores, brokers (stack Terraform) e equivalências do docker-compose |
| [sequence-authorization.md](diagrams/sequence-authorization.md) | Sequência da autorização — caminho feliz, idempotência, outbox, fan-out e dedup |
| [deployment-aws.md](diagrams/deployment-aws.md) | Topologia física AWS da stack (VPC, ECS, dados, eventos, observabilidade) |

## ADRs — [adr/](adr/)

| ADR | Título |
| --- | ------ |
| [ADR-001](adr/ADR-001-clean-hexagonal-architecture.md) | Clean Architecture e Arquitetura Hexagonal |
| [ADR-002](adr/ADR-002-ecs-fargate-runtime.md) | ECS/Fargate como runtime dos serviços |
| [ADR-003](adr/ADR-003-dynamodb-authorization-limit.md) | DynamoDB para Authorization, Limit e Idempotency |
| [ADR-004](adr/ADR-004-idempotency-strategy.md) | Estratégia de idempotência das operações mutantes |
| [ADR-005](adr/ADR-005-eventbridge-sqs.md) | EventBridge + SQS para comunicação assíncrona |
| [ADR-006](adr/ADR-006-transactional-outbox.md) | Transactional Outbox para consistência entre estado e eventos |
| [ADR-007](adr/ADR-007-at-least-once-idempotent-consumers.md) | At-least-once delivery e consumidores idempotentes |
| [ADR-008](adr/ADR-008-centralized-contract-registry.md) | Repositório central e package para contratos de integração |

Índice com status e resumo de cada decisão: [adr/README.md](adr/README.md).

## Fora de docs/

| Local | Conteúdo |
| ----- | -------- |
| [`../terraform/README.md`](../terraform/README.md) | Arquivos da stack, decisão ALB-sem-API-Gateway, divergências reconciliadas com os serviços, validação |
| [`../docker-compose/README.md`](../docker-compose/README.md) | Ambiente local (LocalStack community + relay de outbox local), profiles `ghcr`/`build` |
| [`../README.md`](../README.md) | Visão da plataforma, mapa dos repos da org, demo local, Definition of Done |
