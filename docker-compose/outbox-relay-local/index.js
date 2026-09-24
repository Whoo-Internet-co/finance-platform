/**
 * Outbox Relay LOCAL — Finance Platform (ADR-006: adapter equivalente).
 *
 * Equivalente local do relay Lambda + EventBridge da stack AWS:
 *   DynamoDB Streams (single-table finance-platform-authorization)
 *     -> filtra INSERTs de outbox (entity=OUTBOX / PK=OUTBOX#event_id)
 *     -> fan-out direto para as 3 filas SQS (accounting/fraud/notification),
 *        emulando o envelope que o EventBridge entregaria (campo `detail`).
 *
 * O EventBridge é restrito ao LocalStack Pro; o fan-out direto via SQS mantém
 * o mesmo contrato de mensagem consumido pelos consumers (parser aceita flat
 * OU envelope com `detail`) e preserva o event_id para deduplicação (ADR-007).
 *
 * Sem checkpoint persistido: iteradores TRIM_HORIZON em memória + retry/backoff.
 * At-least-once: em restart o stream é relido do início e os consumers
 * deduplicam por event_id.
 */

const {
  DynamoDBClient,
  DescribeTableCommand,
} = require('@aws-sdk/client-dynamodb');
const {
  DynamoDBStreamsClient,
  DescribeStreamCommand,
  GetShardIteratorCommand,
  GetRecordsCommand,
} = require('@aws-sdk/client-dynamodb-streams');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const { unmarshall } = require('@aws-sdk/util-dynamodb');

const ENDPOINT = process.env.AWS_ENDPOINT_URL || process.env.DYNAMODB_ENDPOINT || 'http://localstack:4566';
const REGION = process.env.AWS_REGION || 'us-east-1';
const TABLE_NAME = process.env.TABLE_NAME || 'finance-platform-authorization';
const QUEUE_URLS = (process.env.QUEUE_URLS || '')
  .split(',')
  .map((u) => u.trim())
  .filter(Boolean);
const EVENT_SOURCE = process.env.EVENT_SOURCE || 'co.whoo-internet.finance.authorization';
const EVENT_DETAIL_TYPE = process.env.EVENT_DETAIL_TYPE || 'TransacaoAutorizada';
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS || 1000);

const clientConfig = {
  region: REGION,
  endpoint: ENDPOINT,
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID || 'test',
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || 'test',
  },
};

const dynamodb = new DynamoDBClient(clientConfig);
const streams = new DynamoDBStreamsClient(clientConfig);
const sqs = new SQSClient(clientConfig);

const log = (level, msg, extra = {}) => {
  console.log(JSON.stringify({ level, msg, service: 'outbox-relay-local', ...extra }));
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitForTable() {
  for (let attempt = 1; ; attempt += 1) {
    try {
      const result = await dynamodb.send(
        new DescribeTableCommand({ TableName: TABLE_NAME }),
      );
      const streamArn = result.Table && result.Table.LatestStreamArn;
      if (streamArn) {
        log('info', 'table ready', { table: TABLE_NAME, streamArn });
        return streamArn;
      }
      log('warn', 'table exists but stream is not enabled', { table: TABLE_NAME });
    } catch (error) {
      log('warn', 'waiting for table', { table: TABLE_NAME, attempt, error: error.message });
    }
    await sleep(Math.min(POLL_INTERVAL_MS * attempt, 5000));
  }
}

async function getShardIterators(streamArn) {
  const described = await streams.send(new DescribeStreamCommand({ StreamArn: streamArn }));
  const shards = (described.StreamDescription && described.StreamDescription.Shards) || [];
  const iterators = [];
  for (const shard of shards) {
    const it = await streams.send(
      new GetShardIteratorCommand({
        StreamArn: streamArn,
        ShardId: shard.ShardId,
        ShardIteratorType: 'TRIM_HORIZON',
      }),
    );
    if (it.ShardIterator) {
      iterators.push({ shardId: shard.ShardId, iterator: it.ShardIterator });
    }
  }
  log('info', 'shard iterators acquired', { shards: iterators.length });
  return iterators;
}

function isOutboxRecord(payload) {
  return (
    payload.entity === 'OUTBOX' ||
    (typeof payload.PK === 'string' && payload.PK.startsWith('OUTBOX#'))
  );
}

/** Emula o envelope que o EventBridge entrega ao target SQS (campo detail). */
function buildEnvelope(payload) {
  return JSON.stringify({
    version: '0',
    id: payload.event_id,
    'detail-type': EVENT_DETAIL_TYPE,
    source: EVENT_SOURCE,
    account: '000000000000',
    time: payload.occurred_at || new Date().toISOString(),
    region: REGION,
    resources: [],
    detail: payload,
  });
}

async function fanOut(payload) {
  const body = buildEnvelope(payload);
  let sent = 0;
  for (const queueUrl of QUEUE_URLS) {
    await sqs.send(
      new SendMessageCommand({
        QueueUrl: queueUrl,
        MessageBody: body,
      }),
    );
    sent += 1;
  }
  log('info', 'event relayed', {
    eventId: payload.event_id,
    idAutorizacao: payload.id_autorizacao,
    queues: sent,
  });
}

async function pollShard(streamArn, shard) {
  const result = await streams.send(
    new GetRecordsCommand({ ShardIterator: shard.iterator, Limit: 100 }),
  );

  for (const record of result.Records || []) {
    if (record.eventName !== 'INSERT' || !record.dynamodb || !record.dynamodb.NewImage) {
      continue;
    }
    const payload = unmarshall(record.dynamodb.NewImage);
    if (!isOutboxRecord(payload)) {
      continue; // INSERTs de contrato/autorização/idempotência na single-table
    }
    if (!payload.event_id) {
      log('warn', 'outbox record without event_id, skipped', {
        sequenceNumber: record.dynamodb.SequenceNumber,
      });
      continue;
    }
    await fanOut(payload);
  }

  if (result.NextShardIterator) {
    shard.iterator = result.NextShardIterator;
  } else {
    // Iterador expirado: re-adquire do shard (TRIM_HORIZON seria reler tudo —
    // consumers deduplicam; mas preferimos refrescar a lista de shards).
    shard.expired = true;
  }
}

async function main() {
  log('info', 'starting', { endpoint: ENDPOINT, table: TABLE_NAME, queues: QUEUE_URLS });
  if (QUEUE_URLS.length === 0) {
    log('error', 'QUEUE_URLS is empty — nothing to relay');
    process.exit(1);
  }

  const streamArn = await waitForTable();
  let shards = await getShardIterators(streamArn);

  for (;;) {
    try {
      for (const shard of shards) {
        if (!shard.expired) {
          await pollShard(streamArn, shard);
        }
      }
      if (shards.every((s) => s.expired) || shards.length === 0) {
        shards = await getShardIterators(streamArn);
      }
    } catch (error) {
      log('error', 'poll cycle failed, retrying', { error: error.message });
      await sleep(POLL_INTERVAL_MS * 2);
      continue;
    }
    await sleep(POLL_INTERVAL_MS);
  }
}

main().catch((error) => {
  log('error', 'fatal', { error: error.message, stack: error.stack });
  process.exit(1);
});
