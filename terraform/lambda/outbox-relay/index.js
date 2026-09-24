/**
 * Outbox Relay — Finance Platform (ADR-006 Transactional Outbox)
 *
 * Lambda (Node 22) disparada pelo DynamoDB Streams da tabela de outbox.
 * Para cada registro INSERT de outbox, publica o evento no EventBridge
 * (custom event bus), preservando o event_id original.
 *
 * A publicação é at-least-once: se o DynamoDB Streams reentregar o registro,
 * o evento será republicado e os consumers deduplicarão por event_id
 * (ADR-005 / ADR-007). Não há dual-write entre banco e event bus: o evento
 * só existe depois do commit da TransactWriteItems do Authorization Service.
 *
 * Dependências: apenas o AWS SDK v3, que já é bundlado no runtime Node 22
 * do Lambda (nenhum layer/package necessário).
 */

const {
  EventBridgeClient,
  PutEventsCommand,
} = require('@aws-sdk/client-eventbridge');

const eventBridge = new EventBridgeClient({
  region: process.env.AWS_REGION || 'us-east-1',
});

const EVENT_BUS_NAME = process.env.EVENT_BUS_NAME;
const EVENT_SOURCE = process.env.EVENT_SOURCE || 'co.whoo-internet.finance.authorization';
const EVENT_DETAIL_TYPE = process.env.EVENT_DETAIL_TYPE || 'TransacaoAutorizada';

/**
 * Unmarshall mínimo do formato DynamoDB (JSON attribute values) para o
 * payload de negócio. Implementado localmente para evitar dependências
 * externas além do SDK bundlado.
 */
function unmarshall(attributeMap) {
  const result = {};
  for (const [key, value] of Object.entries(attributeMap || {})) {
    result[key] = unmarshallValue(value);
  }
  return result;
}

function unmarshallValue(value) {
  if (value === undefined || value === null) return undefined;
  if (value.S !== undefined) return value.S;
  if (value.N !== undefined) {
    // Preserva números inteiros sem ponto flutuante (ex.: 1000), senão converte.
    return /^[+-]?\d+$/.test(value.N) ? Number(value.N) : Number.parseFloat(value.N);
  }
  if (value.BOOL !== undefined) return value.BOOL;
  if (value.NULL !== undefined) return null;
  if (value.L !== undefined) return value.L.map((item) => unmarshallValue(item));
  if (value.M !== undefined) return unmarshall(value.M);
  if (value.SS !== undefined) return value.SS;
  if (value.NS !== undefined) return value.NS.map((n) => Number(n));
  if (value.BS !== undefined) return value.BS;
  if (value.B !== undefined) return value.B;
  return undefined;
}

exports.handler = async (event) => {
  const entries = [];

  for (const record of event.Records || []) {
    // Só eventos de inserção (criação do registro de outbox) geram publicação.
    if (record.eventName !== 'INSERT') {
      continue;
    }

    const newImage = record.dynamodb && record.dynamodb.NewImage;
    if (!newImage) {
      continue;
    }

    const payload = unmarshall(newImage);
    if (!payload.event_id) {
      console.warn('outbox-relay: record without event_id, skipped', {
        sequenceNumber: record.dynamodb && record.dynamodb.SequenceNumber,
      });
      continue;
    }

    entries.push({
      EventBusName: EVENT_BUS_NAME,
      Source: EVENT_SOURCE,
      DetailType: EVENT_DETAIL_TYPE,
      Detail: JSON.stringify(payload),
      // DynamoDB Streams entrega timestamp em segundos (epoch).
      Time: new Date(
        (record.dynamodb.ApproximateCreationDateTime || Date.now() / 1000) * 1000,
      ),
    });
  }

  if (entries.length === 0) {
    console.log('outbox-relay: no publishable records');
    return { published: 0 };
  }

  // PutEvents aceita até 10 entradas por chamada.
  const batches = [];
  for (let i = 0; i < entries.length; i += 10) {
    batches.push(entries.slice(i, i + 10));
  }

  let published = 0;
  let failed = 0;
  for (const batch of batches) {
    const command = new PutEventsCommand({ Entries: batch });
    const result = await eventBridge.send(command);
    const failures = result.FailedEntryCount || 0;
    published += batch.length - failures;
    failed += failures;

    if (failures > 0) {
      // Registra as falhas detalhadas para observabilidade (o stream fará retry).
      for (const entry of result.Entries || []) {
        if (entry.ErrorCode) {
          console.error('outbox-relay: PutEvents failed', {
            eventId: entry.EventId || 'unknown',
            errorCode: entry.ErrorCode,
            errorMessage: entry.ErrorMessage,
          });
        }
      }
    }
  }

  console.log('outbox-relay: published batch', {
    total: entries.length,
    published,
    failed,
    bus: EVENT_BUS_NAME,
  });

  // Lança erro se houver falha para que o DynamoDB Streams reentregue o lote.
  if (failed > 0) {
    throw new Error(`PutEvents failed for ${failed} of ${entries.length} entries`);
  }

  return { published };
};