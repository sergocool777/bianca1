import fs from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

async function readJson(file, fallback) {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return fallback;
    throw err;
  }
}

async function writeJsonAtomic(file, data) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  await fs.writeFile(tmp, JSON.stringify(data, null, 2), 'utf8');
  await fs.rename(tmp, file);
}

/**
 * Долговременная память: список фактов о пользователе (data/memory.json).
 */
export class FactMemory {
  constructor(dataDir) {
    this.file = path.join(dataDir, 'memory.json');
    this.facts = null;
  }

  async load() {
    if (!this.facts) this.facts = (await readJson(this.file, { facts: [] })).facts;
    return this.facts;
  }

  async list() {
    return [...(await this.load())];
  }

  async add(text) {
    const facts = await this.load();
    const clean = String(text ?? '').trim();
    if (!clean) return { ok: false, error: 'Пустой факт' };
    const duplicate = facts.find((f) => f.text.toLowerCase() === clean.toLowerCase());
    if (duplicate) return { ok: true, note: 'Уже было в памяти', fact: duplicate };
    const fact = { id: randomUUID(), text: clean, createdAt: new Date().toISOString() };
    facts.push(fact);
    await writeJsonAtomic(this.file, { facts });
    return { ok: true, fact };
  }

  async remove(query) {
    const facts = await this.load();
    const q = String(query ?? '').trim().toLowerCase();
    if (!q) return { ok: false, error: 'Пустой запрос' };
    const removed = facts.filter((f) => f.id === query || f.text.toLowerCase().includes(q));
    if (removed.length === 0) return { ok: false, error: 'Ничего похожего в памяти нет' };
    this.facts = facts.filter((f) => !removed.includes(f));
    await writeJsonAtomic(this.file, { facts: this.facts });
    return { ok: true, removed: removed.map((f) => f.text) };
  }
}

/**
 * Краткосрочная память: история диалога по сессиям (data/sessions/<id>.json).
 */
export class SessionStore {
  constructor(dataDir, maxHistoryMessages) {
    this.dir = path.join(dataDir, 'sessions');
    this.maxHistory = maxHistoryMessages;
    this.cache = new Map();
    this.locks = new Map();
  }

  fileFor(id) {
    return path.join(this.dir, `${id}.json`);
  }

  async get(id) {
    if (!this.cache.has(id)) {
      const data = await readJson(this.fileFor(id), null);
      this.cache.set(id, data ?? { id, messages: [], pending: [], createdAt: new Date().toISOString() });
    }
    return this.cache.get(id);
  }

  async save(session) {
    session.messages = trimHistory(session.messages, this.maxHistory);
    session.updatedAt = new Date().toISOString();
    await writeJsonAtomic(this.fileFor(session.id), session);
  }

  async reset(id) {
    this.cache.delete(id);
    await fs.rm(this.fileFor(id), { force: true });
  }

  /** Последовательное выполнение ходов одной сессии (без гонок). */
  async withLock(id, task) {
    const prev = this.locks.get(id) ?? Promise.resolve();
    const run = prev.then(task, task);
    const tail = run.catch(() => {});
    this.locks.set(id, tail);
    try {
      return await run;
    } finally {
      if (this.locks.get(id) === tail) this.locks.delete(id);
    }
  }
}

/**
 * Оставляет последние N сообщений, но так, чтобы история начиналась с реплики пользователя
 * (нельзя обрывать цепочку assistant(tool_calls) → tool).
 */
export function trimHistory(messages, max) {
  if (messages.length <= max) return messages;
  let start = messages.length - max;
  while (start < messages.length && messages[start].role !== 'user') start++;
  return messages.slice(start);
}
