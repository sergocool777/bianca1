import Fastify from 'fastify';
import cors from '@fastify/cors';
import { Ollama } from 'ollama';
import { config } from './src/config.js';
import { FactMemory, SessionStore } from './src/memory.js';
import { Agent, AgentError } from './src/agent.js';

const fastify = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } });
await fastify.register(cors, { origin: '*' });

// Разрешаем пустое тело при Content-Type: application/json (например, для DELETE /api/session/:id)
fastify.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body, done) => {
  if (!body || body.trim() === '') return done(null, {});
  try {
    done(null, JSON.parse(body));
  } catch (err) {
    err.statusCode = 400;
    done(err, undefined);
  }
});

const ollama = new Ollama({ host: config.ollamaHost });
const facts = new FactMemory(config.dataDir);
const sessions = new SessionStore(config.dataDir, config.maxHistoryMessages);
const agent = new Agent({
  chat: (request) => ollama.chat({ ...request, stream: false }),
  facts,
  config,
  logger: fastify.log,
});

// Простая авторизация по токену (если задан BIANCA_TOKEN)
fastify.addHook('onRequest', async (request, reply) => {
  if (!config.token || request.url === '/api/health') return;
  if (request.headers['x-bianca-token'] !== config.token) {
    return reply.code(401).send({ error: 'Неверный токен' });
  }
});

const SESSION_ID = { type: 'string', pattern: '^[A-Za-z0-9_-]{1,64}$' };

fastify.get('/api/health', async () => {
  try {
    const { models } = await ollama.list();
    const names = models.map((m) => m.name);
    const modelReady = names.some((n) => n === config.model || n === `${config.model}:latest`);
    return { ok: true, ollama: true, model: config.model, modelReady };
  } catch (err) {
    return { ok: false, ollama: false, model: config.model, error: String(err?.message ?? err) };
  }
});

fastify.post(
  '/api/turn',
  {
    schema: {
      body: {
        type: 'object',
        required: ['sessionId'],
        properties: {
          sessionId: SESSION_ID,
          text: { type: 'string', maxLength: 4000 },
          toolResults: {
            type: 'array',
            maxItems: 20,
            items: {
              type: 'object',
              required: ['id'],
              properties: { id: { type: 'string' }, result: {}, error: { type: 'string' } },
            },
          },
          context: { type: 'object' },
        },
      },
    },
  },
  async (request, reply) => {
    const { sessionId, text, toolResults, context } = request.body;
    if (text) request.log.info({ sessionId, text }, 'user');

    try {
      return await sessions.withLock(sessionId, async () => {
        const session = await sessions.get(sessionId);
        try {
          const result = await agent.turn(session, { text, toolResults, context });
          request.log.info({ sessionId, result }, 'bianca');
          return result;
        } finally {
          await sessions.save(session);
        }
      });
    } catch (err) {
      if (err instanceof AgentError) return reply.code(err.statusCode).send({ error: err.message });
      request.log.error(err, 'turn failed');
      return reply.code(502).send({ error: `Мозг недоступен: ${err?.message ?? err}` });
    }
  },
);

fastify.delete('/api/session/:id', { schema: { params: { type: 'object', properties: { id: SESSION_ID } } } }, async (request) => {
  await sessions.reset(request.params.id);
  return { ok: true };
});

fastify.get('/api/memory', async () => ({ facts: await facts.list() }));

fastify.delete('/api/memory/:id', async (request, reply) => {
  const result = await facts.remove(request.params.id);
  return result.ok ? result : reply.code(404).send(result);
});

try {
  await fastify.listen({ port: config.port, host: config.host });
  fastify.log.info(`🧠 Мозг Бьянки: модель ${config.model}, Ollama ${config.ollamaHost}`);
} catch (err) {
  fastify.log.error(err);
  process.exit(1);
}
