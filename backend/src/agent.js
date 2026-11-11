import { randomUUID } from 'node:crypto';
import { TOOL_SCHEMAS, toolLocation } from './tools.js';
import { buildSystemPrompt } from './prompt.js';

export class AgentError extends Error {
  constructor(message, statusCode = 400) {
    super(message);
    this.statusCode = statusCode;
  }
}

/**
 * Цикл агента.
 * Один «ход» = реплика пользователя (или результаты инструментов телефона) → модель думает,
 * при необходимости вызывает инструменты → либо финальный ответ, либо запрос к телефону.
 */
export class Agent {
  /**
   * @param {object} deps
   * @param {(req: object) => Promise<{message: object}>} deps.chat  обёртка над ollama.chat
   * @param {import('./memory.js').FactMemory} deps.facts
   * @param {object} deps.config
   */
  constructor({ chat, facts, config, logger = console }) {
    this.chat = chat;
    this.facts = facts;
    this.config = config;
    this.log = logger;
  }

  async turn(session, { text, toolResults, context = {} }) {
    const hasText = typeof text === 'string' && text.trim() !== '';
    const hasResults = Array.isArray(toolResults) && toolResults.length > 0;

    if (hasText) {
      if (session.pending?.length) {
        // Пользователь сказал что-то новое, не дождавшись действий — закрываем висящие вызовы
        this.#appendToolResults(session, []);
      }
      session.messages.push({ role: 'user', content: text.trim() });
    } else if (hasResults) {
      if (!session.pending?.length) throw new AgentError('Нет ожидающих вызовов инструментов', 409);
      this.#appendToolResults(session, toolResults);
    } else {
      throw new AgentError('Нужен text или toolResults');
    }

    const facts = await this.facts.list();

    for (let step = 0; step < this.config.maxAgentSteps; step++) {
      const message = await this.#ask(session, facts, context, true);
      const calls = normalizeToolCalls(message.tool_calls);
      const content = cleanText(message.content);

      session.messages.push({
        role: 'assistant',
        content,
        ...(calls.length ? { tool_calls: calls.map(({ id, name, arguments: args }) => ({ id, function: { name, arguments: args } })) } : {}),
      });

      if (calls.length === 0) {
        return { type: 'reply', text: toSpeech(content) };
      }

      const deviceCalls = [];
      for (const call of calls) {
        const where = toolLocation(call.name);
        if (where === 'device') {
          const unavailable = deviceCapabilityError(call, context);
          if (unavailable) {
            session.messages.push({ role: 'tool', tool_name: call.name, content: JSON.stringify(unavailable) });
          } else {
            deviceCalls.push(call);
          }
        } else {
          const result = await this.#runServerTool(call);
          this.log.info?.({ tool: call.name, args: call.arguments, result }, 'server tool');
          session.messages.push({ role: 'tool', tool_name: call.name, content: JSON.stringify(result) });
        }
      }

      if (deviceCalls.length > 0) {
        session.pending = deviceCalls.map(({ id, name }) => ({ id, name }));
        return {
          type: 'tool_calls',
          text: toSpeech(content),
          calls: deviceCalls,
        };
      }
      // Только серверные инструменты — сразу продолжаем думать
    }

    // Лимит шагов исчерпан — просим модель ответить словами, без инструментов
    const message = await this.#ask(session, facts, context, false);
    const content = cleanText(message.content);
    session.messages.push({ role: 'assistant', content });
    return { type: 'reply', text: toSpeech(content) };
  }

  async #ask(session, facts, context, withTools) {
    const noThink = this.config.think === false;
    const system = buildSystemPrompt({ name: this.config.assistantName, facts, context, noThink });
    const request = {
      model: this.config.model,
      messages: [{ role: 'system', content: system }, ...session.messages],
      keep_alive: this.config.keepAlive,
      options: { temperature: this.config.temperature },
      ...(withTools ? { tools: TOOL_SCHEMAS } : {}),
      ...(this.config.think !== undefined ? { think: this.config.think } : {}),
    };
    const response = await this.chat(request);
    return response?.message ?? { role: 'assistant', content: '' };
  }

  #appendToolResults(session, results) {
    const byId = new Map(results.map((r) => [r?.id, r]));
    for (const call of session.pending) {
      const r = byId.get(call.id);
      const payload = r
        ? (r.result ?? { ok: false, status: 'error', errorCode: 'tool_error', error: r.error ?? 'Пустой результат' })
        : {
            ok: false,
            status: 'interrupted',
            errorCode: 'action_interrupted',
            error: 'Действие не выполнено: пользователь перебил или телефон не ответил',
          };
      session.messages.push({ role: 'tool', tool_name: call.name, content: JSON.stringify(payload) });
    }
    session.pending = [];
  }

  async #runServerTool({ name, arguments: args }) {
    try {
      switch (name) {
        case 'remember':
          return await this.facts.add(args.fact);
        case 'forget':
          return await this.facts.remove(args.query);
        default:
          return { error: `Неизвестный инструмент: ${name}` };
      }
    } catch (err) {
      return { error: String(err?.message ?? err) };
    }
  }
}

function deviceCapabilityError(call, context) {
  const capabilities = context.capabilities;
  if (!capabilities) return null;

  if (call.name === 'send_whatsapp' && capabilities.whatsapp?.composerIntent === false) {
    return {
      ok: false,
      status: 'error',
      errorCode: 'capability_unavailable',
      error: 'На телефоне недоступен запуск WhatsApp',
    };
  }
  if (call.name === 'find_contact' && capabilities.contacts === 'permanentlyDenied') {
    return {
      ok: false,
      status: 'error',
      errorCode: 'permission_denied',
      error: 'Доступ к контактам запрещён в настройках телефона',
    };
  }
  if (
    call.name === 'make_call' &&
    capabilities.phone?.directCall !== true &&
    capabilities.phone?.dialer === false
  ) {
    return {
      ok: false,
      status: 'error',
      errorCode: 'capability_unavailable',
      error: 'Телефон не может открыть звонок или номеронабиратель',
    };
  }
  return null;
}

function normalizeToolCalls(toolCalls) {
  if (!Array.isArray(toolCalls)) return [];
  return toolCalls
    .filter((c) => c?.function?.name)
    .map((c) => ({
      id: c.id || randomUUID(),
      name: c.function.name,
      arguments: parseArgs(c.function.arguments),
    }));
}

function parseArgs(args) {
  if (args && typeof args === 'object') return args;
  if (typeof args === 'string') {
    try {
      return JSON.parse(args);
    } catch {
      return {};
    }
  }
  return {};
}

/** Убирает блоки рассуждений, которые иногда протекают в ответ (в т.ч. без открывающего <think>). */
export function cleanText(text) {
  return String(text ?? '')
    .replace(/<think>[\s\S]*?<\/think>/g, '')
    .replace(/^[\s\S]*?<\/think>/g, '')
    .replace(/<think>[\s\S]*$/g, '')
    .trim();
}

/** Готовит текст к озвучке: без markdown-символов и эмодзи. */
export function toSpeech(text) {
  return cleanText(text)
    .replace(/[*_#`>|~]/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\p{Extended_Pictographic}/gu, '')
    .replace(/[ \t]+/g, ' ')
    .replace(/\s*\n\s*/g, ' ')
    .trim();
}
