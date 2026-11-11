import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Подхватываем backend/.env, если он есть (встроено в Node >= 20.12)
try {
  process.loadEnvFile(path.join(ROOT_DIR, '.env'));
} catch {
  // .env необязателен
}

const env = process.env;

function parseThink(value) {
  if (value === undefined || value === '' || value === 'false') return false;
  if (value === 'true') return true;
  if (value === 'auto') return undefined; // не передавать параметр вовсе
  return value; // 'low' | 'medium' | 'high'
}

export const config = {
  port: Number(env.PORT ?? 3000),
  host: env.HOST ?? '0.0.0.0',
  ollamaHost: env.OLLAMA_HOST_URL ?? 'http://127.0.0.1:11434',
  model: env.BIANCA_MODEL ?? 'qwen3:8b',
  think: parseThink(env.BIANCA_THINK),
  temperature: Number(env.BIANCA_TEMPERATURE ?? 0.6),
  keepAlive: env.BIANCA_KEEP_ALIVE ?? '30m',
  // Пустой токен = авторизация выключена (удобно для USB / adb reverse)
  token: env.BIANCA_TOKEN ?? '',
  dataDir: path.resolve(ROOT_DIR, env.BIANCA_DATA_DIR ?? 'data'),
  maxHistoryMessages: Number(env.BIANCA_MAX_HISTORY ?? 40),
  maxAgentSteps: Number(env.BIANCA_MAX_STEPS ?? 6),
  assistantName: env.BIANCA_NAME ?? 'Бьянка',
};
