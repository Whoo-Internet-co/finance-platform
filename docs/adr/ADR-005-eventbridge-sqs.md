# ADR-005 — EventBridge + SQS para comunicação assíncrona

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

Após uma autorização, eventos precisam ser distribuídos para consumidores independentes, inicialmente:

- Accounting;
- Fraud;
- Notification.

Os consumidores devem permanecer desacoplados do Authorization Service e entre si.

Picos ou indisponibilidade de um consumidor não podem bloquear os demais.

## Decisão

Utilizar:

```text
Authorization
      |
      v
EventBridge
      |
      +----------------+----------------+
      |                |                |
      v                v                v
Accounting SQS     Fraud SQS     Notification SQS
      |                |                |
      v                v                v
 Accounting          Fraud         Notification
 Consumer           Consumer        Consumer
```

O **Amazon EventBridge** será responsável por roteamento baseado em eventos/regras.

Cada consumidor possuirá uma **Amazon SQS independente**.

## Responsabilidades

### EventBridge

- roteamento;
- desacoplamento lógico;
- fan-out por regras;
- inclusão futura de consumidores sem alterar o producer.

### SQS

- buffer;
- desacoplamento temporal;
- backpressure;
- retry;
- isolamento de falhas;
- integração com DLQ.

## Semântica

A arquitetura assume **at-least-once delivery**.

Não será assumido exactly-once end-to-end.

Consumers deverão ser idempotentes.

## DLQ

Cada fila deverá possuir sua própria DLQ.

Exemplo:

```text
Fraud Queue
    |
    | failures / maxReceiveCount
    v
Fraud DLQ
```

Isso permite políticas independentes por bounded context.

## Alternativas consideradas

### SNS + SQS

Também permitiria fan-out.

EventBridge foi escolhido por oferecer modelo de roteamento mais expressivo e facilitar evolução para múltiplos tipos de eventos e consumidores.

### Amazon Kinesis

Adequado quando stream processing, throughput contínuo e ordering por shard/partition key forem requisitos centrais.

Não há necessidade suficiente no MVP.

### Kafka / Amazon MSK

Adequado quando replay extensivo, event streaming, consumer groups e ordering por partição justificarem a complexidade operacional.

Não foi escolhido para o escopo atual.

## Ordering

A solução não assume ordenação global.

Consumidores deverão tolerar reordenação quando aplicável.

Caso um bounded context futuro exija ordering estrito por entidade, SQS FIFO, Kinesis ou Kafka poderão ser avaliados conforme o requisito.

## Consequências positivas

- consumidores isolados;
- fan-out;
- absorção de picos;
- retry/DLQ;
- baixo acoplamento;
- novos consumidores sem alteração do producer.

## Consequências negativas

- consistência eventual;
- mensagens podem ser duplicadas;
- ordenação não é garantida globalmente;
- mais componentes de infraestrutura.

## Status

Accepted.
