# Architecture Decision Records (ADRs)

Decisões de arquitetura da Finance Platform. Cada ADR registra contexto,
decisão, motivação, alternativas consideradas e consequências.

| ADR | Título | Status | Resumo |
| --- | ------ | ------ | ------ |
| [ADR-001](ADR-001-clean-hexagonal-architecture.md) | Clean Architecture e Arquitetura Hexagonal | Accepted | Todos os serviços seguem Clean/Hexagonal com direção de dependência Domain ← Application ← Ports ← Adapters; domínio e use cases sem dependência de AWS. |
| [ADR-002](ADR-002-ecs-fargate-runtime.md) | ECS/Fargate como runtime dos serviços | Accepted | Amazon ECS + Fargate executa authorization-service e consumers como containers OCI com auto scaling, em vez de Lambda ou EKS. |
| [ADR-003](ADR-003-dynamodb-authorization-limit.md) | DynamoDB para Authorization, Limit e Idempotency | Accepted | DynamoDB single-table com conditional writes garante reserva atômica de limite e impede overspending sob concorrência, com baixa latência e escala horizontal. |
| [ADR-004](ADR-004-idempotency-strategy.md) | Estratégia de idempotência das operações mutantes | Accepted | Header `Idempotency-Key` com `request_hash` persistido: acquire atômico, replay equivalente retorna `200` com o resultado original, chave com payload divergente retorna `409`. |
| [ADR-005](ADR-005-eventbridge-sqs.md) | EventBridge + SQS para comunicação assíncrona | Accepted | EventBridge com fan-out para uma fila SQS por consumer (accounting, fraud, notification), desacoplando produtores e consumidores com isolamento de falhas. |
| [ADR-006](ADR-006-transactional-outbox.md) | Transactional Outbox para consistência entre estado e eventos | Accepted | Estado e evento de outbox são gravados na mesma transação DynamoDB (`TransactWriteItems`); relay via DynamoDB Streams publica ao EventBridge, eliminando dual write não atômico. |
| [ADR-007](ADR-007-at-least-once-idempotent-consumers.md) | At-least-once delivery e consumidores idempotentes | Accepted | Semântica at-least-once assumida explicitamente; todo consumer com efeito observável deduplica por `event_id` e mensagens não processáveis vão para DLQ. |
| [ADR-008](ADR-008-centralized-contract-registry.md) | Repositório central e package para contratos de integração | Accepted | `finance-platform-contracts` é a source of truth de schemas/OpenAPI, distribuído como package npm versionado no GitHub Packages; não é shared-domain library. |

## Convenções

- Formato: contexto → decisão → motivação → alternativas → consequências.
- Novos ADRs: próximo número sequencial, status inicial `Proposed`.
- ADRs são imutáveis após `Accepted`; revisões geram novo ADR que
  referencia o anterior (`Supersedes` / `Superseded by`).

## Relação com os diagrams

Os diagramas em [`docs/diagrams/`](../diagrams/) refletem as decisões acima:
C4 Context/Container (visão geral), sequência de autorização (ADR-003/004/006)
e deploy AWS (ADR-002/005).
