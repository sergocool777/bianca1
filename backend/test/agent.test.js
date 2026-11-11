import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Agent, toSpeech } from '../src/agent.js';
import { FactMemory, trimHistory } from '../src/memory.js';

const baseConfig = { model: 'test', maxAgentSteps: 6, assistantName: 'Бьянка', temperature: 0.5, keepAlive: '1m', think: false };

async function makeAgent(script) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'bianca-'));
  const facts = new FactMemory(dir);
  const requests = [];
  const chat = async (req) => {
    requests.push(structuredClone(req));
    const next = script.shift();
    if (!next) throw new Error('Скрипт модели закончился');
    return { message: { role: 'assistant', ...next } };
  };
  return { agent: new Agent({ chat, facts, config: baseConfig, logger: {} }), facts, requests };
}

const newSession = () => ({ id: 's', messages: [], pending: [] });
const call = (name, args) => ({ function: { name, arguments: args } });

test('обычный разговор: ответ формулирует модель', async () => {
  const { agent, requests } = await makeAgent([{ content: 'Привет! Чем помочь?' }]);
  const session = newSession();
  const res = await agent.turn(session, { text: 'Привет' });
  assert.deepEqual(res, { type: 'reply', text: 'Привет! Чем помочь?' });
  assert.equal(requests[0].messages[0].role, 'system');
  assert.ok(requests[0].tools.length > 0);
  assert.equal(requests[0].think, false);
});

test('телефонные инструменты уходят на устройство, результат возвращается модели', async () => {
  const { agent, requests } = await makeAgent([
    { content: '', tool_calls: [call('find_contact', { query: 'Мама' })] },
    { content: '', tool_calls: [call('make_call', { phone: '+77010000000', name: 'Мама' })] },
    { content: 'Набираю маму.' },
  ]);
  const session = newSession();

  const r1 = await agent.turn(session, { text: 'Позвони маме' });
  assert.equal(r1.type, 'tool_calls');
  assert.equal(r1.calls[0].name, 'find_contact');
  assert.deepEqual(r1.calls[0].arguments, { query: 'Мама' });

  const r2 = await agent.turn(session, {
    toolResults: [{ id: r1.calls[0].id, result: { contacts: [{ name: 'Мама', phones: ['+77010000000'] }] } }],
  });
  assert.equal(r2.type, 'tool_calls');
  assert.equal(r2.calls[0].name, 'make_call');
  const toolMsg = requests[1].messages.at(-1);
  assert.equal(toolMsg.role, 'tool');
  assert.equal(toolMsg.tool_name, 'find_contact');
  assert.match(toolMsg.content, /77010000000/);

  const r3 = await agent.turn(session, { toolResults: [{ id: r2.calls[0].id, result: { ok: true } }] });
  assert.deepEqual(r3, { type: 'reply', text: 'Набираю маму.' });
  assert.deepEqual(session.pending, []);
});

test('серверный инструмент remember выполняется сразу и попадает в промпт', async () => {
  const { agent, facts, requests } = await makeAgent([
    { content: '', tool_calls: [call('remember', { fact: 'Пользователь любит латте без сахара' })] },
    { content: 'Запомнила!' },
    { content: 'Латте без сахара.' },
  ]);
  const session = newSession();
  const r1 = await agent.turn(session, { text: 'Запомни, я люблю латте без сахара' });
  assert.deepEqual(r1, { type: 'reply', text: 'Запомнила!' });
  assert.equal((await facts.list()).length, 1);

  await agent.turn(newSession(), { text: 'Что я люблю пить?' });
  assert.match(requests[2].messages[0].content, /латте без сахара/);
});

test('новая реплика при висящем вызове закрывает его ошибкой', async () => {
  const { agent, requests } = await makeAgent([
    { content: '', tool_calls: [call('get_location', {})] },
    { content: 'Хорошо, не буду.' },
  ]);
  const session = newSession();
  await agent.turn(session, { text: 'Где я?' });
  await agent.turn(session, { text: 'Не надо' });
  const msgs = requests[1].messages;
  assert.equal(msgs.at(-2).role, 'tool');
  assert.match(msgs.at(-2).content, /не выполнено/);
  assert.equal(msgs.at(-1).content, 'Не надо');
});

test('лимит шагов: финальный ответ без инструментов', async () => {
  const loop = Array.from({ length: 6 }, () => ({ content: '', tool_calls: [call('remember', { fact: 'x' })] }));
  const { agent, requests } = await makeAgent([...loop, { content: 'Готово.' }]);
  const res = await agent.turn(newSession(), { text: 'зациклись' });
  assert.deepEqual(res, { type: 'reply', text: 'Готово.' });
  assert.equal(requests.at(-1).tools, undefined);
});

test('backend не отправляет WhatsApp вызов при недоступной capability', async () => {
  const { agent, requests } = await makeAgent([
    { content: '', tool_calls: [call('send_whatsapp', { phone: '+77010000000', name: 'Мама', text: 'Привет' })] },
    { content: 'Не могу открыть WhatsApp на этом телефоне.' },
  ]);

  const res = await agent.turn(newSession(), {
    text: 'Отправь маме привет',
    context: { capabilities: { whatsapp: { composerIntent: false, automaticSend: false } } },
  });
  assert.equal(res.type, 'reply');
  assert.equal(res.text, 'Не могу открыть WhatsApp на этом телефоне.');
  const toolMessage = requests[1].messages.at(-1);
  assert.equal(toolMessage.role, 'tool');
  assert.match(toolMessage.content, /capability_unavailable/);
  assert.match(requests[1].messages[0].content, /автоматическая отправка недоступна/);
});

test('toSpeech чистит разметку и think-блоки', () => {
  assert.equal(toSpeech('<think>хм</think>**Привет**, это `код` 😀\n- пункт'), 'Привет, это код - пункт');
  assert.equal(toSpeech('рассуждения без открывающего тега\n</think>\n\nЗдравствуй!'), 'Здравствуй!');
});

test('trimHistory начинает историю с реплики пользователя', () => {
  const msgs = [
    { role: 'user', content: '1' },
    { role: 'assistant', content: '', tool_calls: [] },
    { role: 'tool', content: '{}' },
    { role: 'assistant', content: 'ok' },
    { role: 'user', content: '2' },
    { role: 'assistant', content: 'ok2' },
  ];
  assert.deepEqual(trimHistory(msgs, 4).map((m) => m.content), ['2', 'ok2']);
});
