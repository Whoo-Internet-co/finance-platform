# ADR-001 — Clean Architecture e Arquitetura Hexagonal

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

A plataforma de autorização financeira precisa manter regras de domínio isoladas de detalhes tecnológicos e permitir testes automatizados sem dependência de infraestrutura AWS.

O desafio técnico exige explicitamente aplicação de SOLID, Clean Code, Clean/Hexagonal Architecture, DDD e separação via Ports & Adapters.

## Decisão

Todos os serviços serão estruturados segundo Clean Architecture e Arquitetura Hexagonal.

A direção de dependências será:

```text
Domain
  ↑
Application
  ↑
Ports
  ↑
Adapters / Infrastructure
```

O domínio e os casos de uso não poderão depender diretamente de:

- AWS SDK;
- DynamoDB;
- SQS;
- EventBridge;
- API Gateway;
- frameworks HTTP;
- bibliotecas de persistência.

Integrações externas serão representadas por ports e implementadas por adapters.

Exemplos:

```text
IdempotencyRepository
LimitRepository
DomainEventPublisher
EventSchemaValidator
```

Adapters concretos poderão incluir:

```text
DynamoDbLimitRepository
DynamoDbIdempotencyRepository
EventBridgeEventPublisher
SqsConsumer
```

## Alternativas consideradas

### Arquitetura tradicional Controller → Service → Repository

Rejeitada como padrão principal por aumentar o risco de acoplamento entre regras de negócio, framework e infraestrutura.

### Compartilhamento de lógica de domínio entre microsserviços

Rejeitado. Cada bounded context deve preservar autonomia de domínio.

## Consequências positivas

- alta testabilidade;
- isolamento do domínio;
- substituição de adapters sem alterar regras de negócio;
- execução local com adapters in-memory;
- melhor aplicação de Dependency Inversion;
- maior clareza das fronteiras arquiteturais.

## Consequências negativas

- maior quantidade de interfaces;
- estrutura inicial mais elaborada;
- risco de abstrações desnecessárias se aplicada mecanicamente.

## Regras

1. Domain não importa Infrastructure.
2. Application depende de abstrações.
3. AWS SDK fica restrito aos adapters/infrastructure.
4. Testes do domínio não dependem de AWS.
5. Frameworks são detalhes de implementação.

## Status

Accepted.
