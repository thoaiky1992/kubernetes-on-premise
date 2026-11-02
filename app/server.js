import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { format } from 'node:util';
import { Worker } from 'node:worker_threads';
import { Client } from '@elastic/elasticsearch';
import { Cluster } from 'ioredis';

const SERVICE = 'node-api';
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const minLevel = LEVELS[process.env.LOG_LEVEL ?? 'info'] ?? LEVELS.info;

// Mỗi dòng log là một object JSON: ts, level, service, event, cộng các trường theo sự kiện.
// Các dòng của cùng một request hoặc cùng một lần kiểm tra backend có chung trace_id.
function log(level, event, fields = {}) {
  if (LEVELS[level] < minLevel) return;
  const line = JSON.stringify({ ts: new Date().toISOString(), level, service: SERVICE, event, ...fields });
  (LEVELS[level] >= LEVELS.warn ? process.stderr : process.stdout).write(`${line}\n`);
}

// Đưa các lời gọi console về log JSON để mọi dòng stdout/stderr đều parse được.
console.log = (...args) => log('info', 'library.log', { message: format(...args) });
console.info = (...args) => log('info', 'library.log', { message: format(...args) });
console.warn = (...args) => log('warn', 'library.log', { message: format(...args) });
console.error = (...args) => log('error', 'library.log', { message: format(...args) });

function errorInfo(error) {
  return {
    name: error?.name ?? 'Error',
    message: error instanceof Error ? error.message : String(error),
    ...(error?.code !== undefined && { code: error.code }),
  };
}

function elapsed(started) {
  return Math.round((performance.now() - started) * 100) / 100;
}

function newTraceId() {
  return randomBytes(16).toString('hex');
}

// Nhận trace-id từ traceparent theo W3C Trace Context; không có thì tự sinh.
const TRACEPARENT = /^00-([0-9a-f]{32})-[0-9a-f]{16}-[0-9a-f]{2}$/;
function traceIdFrom(request) {
  const match = TRACEPARENT.exec(request.headers.traceparent ?? '');
  return match ? match[1] : newTraceId();
}

// Mỗi backend chỉ được kết nối khi cờ tương ứng là 'true'; biến của backend bị tắt không bắt buộc.
const BACKENDS = {
  elasticsearch: {
    flag: 'ELASTICSEARCH_ENABLED',
    required: [
      'ELASTICSEARCH_URL',
      'ELASTICSEARCH_USERNAME',
      'ELASTICSEARCH_PASSWORD',
      'ELASTICSEARCH_CA_FILE',
    ],
  },
  redis_cluster: {
    flag: 'REDIS_CLUSTER_ENABLED',
    required: [
      'REDIS_CLUSTER_HOST',
      'REDIS_CLUSTER_PORT',
      'REDIS_CLUSTER_PASSWORD',
      'REDIS_CLUSTER_CA_FILE',
    ],
  },
};

const enabled = Object.keys(BACKENDS).filter(name => process.env[BACKENDS[name].flag] === 'true');
log('info', 'config.backends', { enabled, disabled: Object.keys(BACKENDS).filter(name => !enabled.includes(name)) });

for (const name of enabled) {
  for (const variable of BACKENDS[name].required) {
    if (!process.env[variable]) {
      log('error', 'config.missing_env', { backend: name, variable });
      process.exit(1);
    }
  }
}

if (enabled.includes('elasticsearch') && !process.env.ELASTICSEARCH_URL.startsWith('https://')) {
  log('error', 'config.invalid_url', { variable: 'ELASTICSEARCH_URL', reason: 'must use https://' });
  process.exit(1);
}

function parsePort(name) {
  const port = Number(process.env[name]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    log('error', 'config.invalid_port', { variable: name });
    process.exit(1);
  }
  return port;
}

function loadCa(backend, path) {
  try {
    return readFileSync(path);
  } catch (error) {
    log('error', 'config.ca_unreadable', { backend, path, error: errorInfo(error) });
    process.exit(1);
  }
}

// Mỗi backend được bật sẽ có client, backend bị tắt không tạo kết nối nào.
const backends = {};
const clients = {};

if (enabled.includes('elasticsearch')) {
  const elasticsearchCa = loadCa('elasticsearch', process.env.ELASTICSEARCH_CA_FILE);
  const elasticsearch = new Client({
    node: process.env.ELASTICSEARCH_URL,
    auth: {
      username: process.env.ELASTICSEARCH_USERNAME,
      password: process.env.ELASTICSEARCH_PASSWORD,
    },
    tls: { ca: elasticsearchCa, rejectUnauthorized: true },
    requestTimeout: 5000,
  });
  clients.elasticsearch = elasticsearch;
  backends.elasticsearch = {
    ready: () => true,
    ping: async traceId => {
      // opaqueId đi vào header X-Opaque-Id, để tìm cùng trace_id trong log của Elasticsearch.
      if (!(await elasticsearch.ping({}, { opaqueId: traceId }))) {
        throw new Error('ping returned false');
      }
    },
  };
}

if (enabled.includes('redis_cluster')) {
  const clusterPort = parsePort('REDIS_CLUSTER_PORT');
  const clusterCa = loadCa('redis_cluster', process.env.REDIS_CLUSTER_CA_FILE);
  // Redis Cluster: client đọc topology từ root node rồi tự định tuyến theo slot (MOVED/ASK).
  // redisOptions áp dụng cho cả kết nối discovery lẫn kết nối tới từng node.
  const cluster = new Cluster([{ host: process.env.REDIS_CLUSTER_HOST, port: clusterPort }], {
    // Preserve Redis-advertised DNS names so TLS verifies their certificate SANs.
    dnsLookup: (address, callback) => callback(null, address),
    redisOptions: {
      password: process.env.REDIS_CLUSTER_PASSWORD,
      tls: { ca: clusterCa, rejectUnauthorized: true },
    },
  });
  clients.redis_cluster = cluster;
  backends.redis_cluster = {
    ready: () => cluster.status === 'ready',
    ping: async () => expectPong(await cluster.ping()),
  };
}

function expectPong(reply) {
  if (reply !== 'PONG') throw new Error(`unexpected PING reply: ${reply}`);
}

// Lệnh có thể chờ vô hạn khi client đang kết nối lại (ví dụ lúc failover), nên mỗi lần ping có thời hạn.
const CHECK_TIMEOUT_MS = 3000;
function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`no reply within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

const state = Object.fromEntries(enabled.map(name => [name, { ok: false }]));

function setState(name, result, traceId) {
  const previous = state[name].ok;
  state[name] = { ...result, checked_at: new Date().toISOString() };
  if (previous !== result.ok) {
    log(result.ok ? 'info' : 'error', result.ok ? 'backend.up' : 'backend.down', {
      backend: name,
      trace_id: traceId,
      ...(result.error && { error: result.error }),
    });
  }
  return state[name];
}

async function checkBackend(name, traceId) {
  const backend = backends[name];
  const started = performance.now();
  let result;
  try {
    if (!backend.ready()) throw new Error('client is not connected');
    await withTimeout(backend.ping(traceId), CHECK_TIMEOUT_MS);
    result = { ok: true };
  } catch (error) {
    result = { ok: false, error: errorInfo(error) };
  }
  const durationMs = elapsed(started);
  log(result.ok ? 'info' : 'error', 'backend.check', {
    backend: name,
    trace_id: traceId,
    ok: result.ok,
    duration_ms: durationMs,
    ...(result.error && { error: result.error }),
  });
  return setState(name, { ...result, duration_ms: durationMs }, traceId);
}

async function checkAll(traceId) {
  const names = Object.keys(backends);
  const results = await Promise.all(names.map(name => checkBackend(name, traceId)));
  return Object.fromEntries(names.map((name, i) => [name, results[i]]));
}

// Các client tự kết nối và tự thử lại khi mất kết nối; chỉ cần ghi nhận trạng thái theo sự kiện.
if (clients.redis_cluster) {
  const cluster = clients.redis_cluster;
  cluster.on('ready', () => {
    log('info', 'backend.connected', { backend: 'redis_cluster' });
    void checkBackend('redis_cluster', newTraceId());
  });
  cluster.on('reconnecting', () => {
    setState('redis_cluster', { ok: false, error: { message: 'reconnecting to Redis Cluster' } }, undefined);
  });
  cluster.on('end', () => {
    setState('redis_cluster', { ok: false, error: { message: 'connection closed' } }, undefined);
  });
  cluster.on('error', error => {
    log('error', 'redis_cluster.error', { error: errorInfo(error) });
  });
}

function sendJson(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(body));
}

// Stress test, hai API tách riêng, mỗi loại chỉ chạy một job tại một thời điểm:
//   /api/stress/cpu?workers=<1-4>&duration=<giây>     chạy CPU trong worker thread để event loop vẫn trả lời probe
//   /api/stress/memory?memory_mb=<0-1024>&duration=<giây>  cấp phát và ghi đầy RAM để tính vào RSS
// Giới hạn cứng để tránh làm sập pod.
const STRESS_LIMITS = {
  workers: { default: 1, max: 4 },
  memory_mb: { default: 128, max: 1024 },
  duration: { default: 30, max: 300 },
};
const CPU_BURN = `
  const { workerData } = require('node:worker_threads');
  const end = Date.now() + workerData.durationMs;
  let x = 0;
  while (Date.now() < end) x = Math.sqrt(x + Math.random());
`;
const stressJobs = { cpu: null, memory: null };

function stressParam(url, name) {
  const { default: fallback, max } = STRESS_LIMITS[name];
  const raw = url.searchParams.get(name);
  if (raw === null) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 0 || value > max) {
    throw new RangeError(`${name} must be an integer from 0 to ${max}`);
  }
  return value;
}

// Trả về job nếu bắt đầu được, null nếu cùng loại đang chạy.
function startStress(kind, details, traceId) {
  if (stressJobs[kind]) return null;
  const durationMs = details.duration_seconds * 1000;
  const job = { trace_id: traceId, started_at: new Date().toISOString(), ...details };
  stressJobs[kind] = job;
  log('info', 'stress.started', { kind, ...job });
  setTimeout(() => {
    stressJobs[kind] = null;
    log('info', 'stress.finished', { kind, trace_id: traceId });
  }, durationMs).unref();
  return job;
}

function startCpuStress(workers, duration, traceId) {
  const durationMs = duration * 1000;
  const job = startStress('cpu', { workers, duration_seconds: duration }, traceId);
  if (!job) return null;
  for (let i = 0; i < workers; i++) {
    const worker = new Worker(CPU_BURN, { eval: true, workerData: { durationMs } });
    worker.on('error', error => log('error', 'stress.worker_error', { kind: 'cpu', trace_id: traceId, error: errorInfo(error) }));
  }
  return job;
}

function startMemoryStress(memoryMb, duration, traceId) {
  // Buffer.alloc điền số 0 vào toàn bộ vùng nhớ, nên RSS tăng thật chứ không chỉ là cấp phát ảo.
  const job = startStress('memory', { memory_mb: memoryMb, duration_seconds: duration }, traceId);
  if (!job) return null;
  let buffer = Buffer.alloc(memoryMb * 1024 * 1024);
  // Giữ tham chiếu tới khi hết thời gian, sau đó bỏ để GC thu hồi.
  setTimeout(() => { buffer = null; }, duration * 1000).unref();
  return job;
}

const server = createServer(async (request, response) => {
  const started = performance.now();
  const traceId = traceIdFrom(request);
  const url = new URL(request.url ?? '/', 'http://localhost');
  const { pathname } = url;
  response.setHeader('x-trace-id', traceId);
  response.on('finish', () => {
    // Probe gọi đều đặn nên ghi ở mức debug để log info không bị nhiễu.
    const probe = pathname === '/healthz' || pathname === '/readyz';
    log(probe ? 'debug' : 'info', 'http.request', {
      trace_id: traceId,
      method: request.method,
      path: pathname,
      status: response.statusCode,
      duration_ms: elapsed(started),
    });
  });

  if (request.method !== 'GET') {
    sendJson(response, 405, { trace_id: traceId, error: 'method not allowed' });
    return;
  }
  if (pathname === '/healthz') {
    response.writeHead(200).end('ok');
    return;
  }
  if (pathname === '/readyz') {
    const ready = Object.values(state).every(service => service.ok);
    sendJson(response, ready ? 200 : 503, { ready, trace_id: traceId, services: state });
    return;
  }
  if (pathname === '/api/check') {
    const services = await checkAll(traceId);
    const ok = Object.values(services).every(service => service.ok);
    sendJson(response, ok ? 200 : 503, { ok, trace_id: traceId, services });
    return;
  }
  if (pathname === '/api/stress/cpu' || pathname === '/api/stress/memory') {
    const kind = pathname === '/api/stress/cpu' ? 'cpu' : 'memory';
    let params;
    try {
      params = kind === 'cpu'
        ? { workers: stressParam(url, 'workers'), duration: stressParam(url, 'duration') }
        : { memoryMb: stressParam(url, 'memory_mb'), duration: stressParam(url, 'duration') };
    } catch (error) {
      sendJson(response, 400, { trace_id: traceId, error: error.message });
      return;
    }
    const job = kind === 'cpu'
      ? startCpuStress(params.workers, params.duration, traceId)
      : startMemoryStress(params.memoryMb, params.duration, traceId);
    if (!job) {
      sendJson(response, 409, { trace_id: traceId, error: `a ${kind} stress job is already running`, job: stressJobs[kind] });
      return;
    }
    sendJson(response, 202, { trace_id: traceId, job });
    return;
  }
  sendJson(response, 404, { trace_id: traceId, error: 'not found' });
});

const port = Number(process.env.PORT || 3000);
server.listen(port, '0.0.0.0', () => {
  log('info', 'app.listening', { port });
});

void checkAll(newTraceId());
setInterval(() => { void checkAll(newTraceId()); }, 15000);

async function shutdown(signal) {
  log('info', 'app.shutdown', { signal });
  server.close();
  await Promise.allSettled(Object.values(clients).map(client => client.quit?.() ?? client.close()));
  process.exit(0);
}

process.on('SIGTERM', () => { void shutdown('SIGTERM'); });
process.on('SIGINT', () => { void shutdown('SIGINT'); });
process.on('uncaughtException', error => {
  log('error', 'process.uncaught_exception', { error: errorInfo(error) });
  process.exit(1);
});
process.on('unhandledRejection', reason => {
  log('error', 'process.unhandled_rejection', { error: errorInfo(reason) });
  process.exit(1);
});
