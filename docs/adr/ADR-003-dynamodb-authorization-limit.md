# ADR-003 — DynamoDB para Authorization, Limit e Idempotency

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

O domínio de autorização precisa:

- consultar dados por identificadores conhecidos;
- reservar limite com baixa latência;
- impedir overspending sob concorrência;
- manter idempotência;
- suportar alto throughput;
- escalar horizontalmente.

O requisito crítico é garantir que requisições concorrentes não reservem um limite superior ao disponível.

Exemplo:

```text
Limite disponível = 1.000

Request A = 700
Request B = 700
```

Somente uma das duas reservas pode ser aceita.

## Decisão

Utilizar **Amazon DynamoDB** como persistência principal para o caminho crítico de autorização/limite.

A atualização de limite utilizará operações condicionais e/ou transações DynamoDB.

Invariante principal:

```text
available_limit >= requested_amount
```

A reserva deve ser feita atomicamente.

Exemplo conceitual:

```text
SET available_limit = available_limit - :amount
CONDITION available_limit >= :amount
```

Quando múltiplos itens precisarem participar da mesma unidade atômica, será utilizado `TransactWriteItems`.

## Modelo

A modelagem deverá ser orientada aos access patterns, e não à normalização relacional.

Os principais conceitos persistidos incluem:

- Contract/Limit;
- Authorization;
- Idempotency;
- Outbox Event.

A modelagem física final poderá utilizar uma ou mais tabelas conforme os access patterns e necessidades de isolamento.

## Concorrência

A consistência não será implementada através de lock distribuído externo.

Conditional Writes / TransactWriteItems preservarão as invariantes no próprio datastore.

## Alternativas consideradas

### Amazon Aurora PostgreSQL

É uma alternativa válida e oferece:

- transações ACID;
- constraints;
- locking;
- SQL;
- modelo relacional.

Não foi escolhida para o caminho crítico porque os access patterns principais são orientados a chave e DynamoDB fornece operações condicionais atômicas adequadas ao requisito de reserva concorrente e escalabilidade horizontal.

Aurora deverá ser reconsiderado caso consultas relacionais complexas, joins ou requisitos transacionais multi-entidade passem a dominar o sistema.

## Consequências positivas

- baixa latência;
- escalabilidade horizontal;
- conditional writes;
- transações;
- integração AWS;
- ausência de pool de conexões relacional.

## Consequências negativas

- modelagem exige conhecimento prévio dos access patterns;
- consultas ad hoc são limitadas;
- transações complexas entre muitos agregados não são o caso ideal;
- risco de hot partitions se as partition keys forem mal escolhidas.

## Teste arquitetural obrigatório

Deve existir teste concorrente equivalente a:

```text
available = 1000

reserve(700)
reserve(700)
```

Resultado:

```text
1 sucesso
1 rejeição/conflito
```

Nunca duas reservas bem-sucedidas.

## Status

Accepted.
