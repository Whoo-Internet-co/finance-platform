# ADR-008 — Repositório central e package para contratos de integração

- **Status:** Accepted
- **Data:** 2026-09-24
- **Escopo:** Finance Platform

## Contexto

A plataforma utiliza contratos HTTP e eventos compartilhados entre serviços.

Inicialmente:

- Authorization Service produz `TransacaoAutorizada`;
- Accounting Consumer consome o evento;
- Fraud Consumer consome o evento;
- Notification Consumer consome o evento.

Se cada repositório mantiver sua própria versão canônica do schema, ocorrerá risco de **contract drift**.

A plataforma também adota contract-first para APIs e evolução retrocompatível dos eventos.

## Decisão

Criar um repositório independente:

```text
finance-platform-contracts
```

Ele será a **source of truth** dos contratos públicos da plataforma.

Inicialmente conterá:

```text
events/
  transacao-autorizada/
    v1/
      schema.json
      example.json

openapi/
  authorization/
    v1/
      openapi.yaml
```

## Distribuição

Os contratos serão publicados como package npm versionado no **GitHub Packages**:

```text
@<github-owner>/finance-platform-contracts
```

Serviços deverão declarar explicitamente a versão utilizada.

Exemplo:

```json
{
  "dependencies": {
    "@<github-owner>/finance-platform-contracts": "1.0.0"
  }
}
```

## O que o package é

Um mecanismo de governança e distribuição de:

- JSON Schema;
- OpenAPI;
- exemplos;
- metadados/artefatos de validação.

## O que o package NÃO é

Não será uma shared-domain library.

Não deverá compartilhar:

- entidades com comportamento;
- use cases;
- repositories;
- regras de negócio;
- serviços de domínio.

Os microsserviços permanecem autônomos.

## Source of Truth

JSON Schema será canônico para contratos de eventos.

OpenAPI será canônico para contratos HTTP.

Tipos TypeScript, se fornecidos, deverão ser derivados/gerados a partir do schema.

Não serão mantidas manualmente duas representações independentes do mesmo contrato.

## Producer Contract Testing

O Authorization Service deverá validar eventos produzidos contra o schema oficial:

```text
produced event
     |
     v
official JSON Schema
     |
  PASS/FAIL
```

## Consumer Contract Testing

Consumers deverão testar compatibilidade utilizando o contrato oficial:

```text
official schema/example
        |
        v
consumer
        |
     PASS/FAIL
```

## Versionamento

Será utilizado Semantic Versioning.

### PATCH

- documentação;
- tooling;
- correções sem alteração observável do contrato.

### MINOR

Mudanças backward-compatible:

- novo campo opcional;
- novos exemplos compatíveis.

### MAJOR

Breaking changes:

- remoção de campo;
- renomeação incompatível;
- alteração incompatível de tipo;
- campo opcional transformado em obrigatório;
- mudança semântica incompatível.

Versões publicadas serão imutáveis.

## Versionamento do evento vs package

São conceitos diferentes.

O package:

```text
finance-platform-contracts@1.4.0
```

pode conter:

```text
events/transacao-autorizada/v1/schema.json
```

Uma futura versão incompatível poderá coexistir:

```text
transacao-autorizada/
  v1/
  v2/
```

Isso permite migração gradual de producers e consumers.

## Compatibilidade

A política de JSON Schema deverá permitir evolução aditiva compatível.

`additionalProperties: false` não deverá ser utilizado indiscriminadamente se impedir consumers antigos de tolerar novos campos opcionais.

## CloudEvents

Os eventos deverão seguir/evoluir para o formato CloudEvents.

A distinção entre:

- envelope técnico CloudEvents;
- payload de negócio;

deverá permanecer explícita.

Mudanças de representação não poderão introduzir breaking changes silenciosamente.

## GitHub Packages

A publicação ocorrerá por GitHub Actions.

Autenticação:

```text
GITHUB_TOKEN
```

Nenhuma credencial deverá ser versionada.

Releases utilizarão tags SemVer:

```text
v1.0.0
v1.1.0
v2.0.0
```

A Git tag e `package.json.version` deverão ser consistentes.

## AWS Schema Registry

O package e um AWS Schema Registry possuem responsabilidades complementares.

Git/package fornece:

- versionamento;
- Pull Requests;
- code review;
- CI;
- testes locais;
- producer/consumer contract tests.

Um Schema Registry AWS poderá fornecer governança operacional durante deployment/runtime.

A integração AWS será responsabilidade da infraestrutura da plataforma.

## Alternativas consideradas

### Cópia manual dos schemas em cada serviço

Rejeitada devido a contract drift e múltiplas fontes de verdade.

### Git Submodules

Rejeitada devido à complexidade operacional e pior experiência de desenvolvimento/CI.

### Biblioteca TypeScript compartilhando domínio

Rejeitada por criar acoplamento tecnológico e de domínio.

### Somente AWS Schema Registry

Rejeitada como única solução porque não substitui Git, Pull Requests, code review e testes locais.

## Governança

Alterações de contratos deverão:

1. ocorrer via Pull Request;
2. passar por validação automatizada;
3. avaliar backward compatibility;
4. respeitar Semantic Versioning;
5. receber revisão adequada;
6. publicar nova versão quando aprovadas.

## Consequências positivas

- source of truth única;
- menor contract drift;
- contract-first;
- producer contract testing;
- consumer contract testing;
- builds reproduzíveis;
- governança explícita.

## Consequências negativas

- novo repositório;
- processo adicional para alteração;
- dependência precisa ser atualizada pelos serviços;
- GitHub Packages pode exigir autenticação para packages privados.

## Status

Accepted.
