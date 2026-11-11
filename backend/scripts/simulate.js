// Имитатор телефона: гоняет реальные диалоги через запущенный бэкенд + Ollama.
// Использование:
//   npm run simulate                          — сценарий по умолчанию
//   npm run simulate -- "Позвони маме" "..."   — свои фразы
// Переменные: BIANCA_URL (http://127.0.0.1:3000), BIANCA_TOKEN

const BASE = process.env.BIANCA_URL ?? 'http://127.0.0.1:3000';
const TOKEN = process.env.BIANCA_TOKEN ?? '';
const sessionId = `sim-${Date.now()}`;

const CONTACTS = [
  { name: 'Мама', phones: ['+7 701 111 22 33'] },
  { name: 'Сергей Петров', phones: ['+7 702 444 55 66'] },
  { name: 'Сергей Работа', phones: ['+7 705 777 88 99'] },
  { name: 'Аня', phones: ['+7 707 000 11 22'] },
];

// Фейковые реализации инструментов телефона
const deviceTools = {
  find_contact: ({ query = '' }) => {
    const q = query.toLowerCase().slice(0, 4);
    const found = CONTACTS.filter((c) => c.name.toLowerCase().includes(q));
    return found.length ? { contacts: found } : { contacts: [], note: 'Контакт не найден' };
  },
  make_call: ({ phone, name }) => ({ ok: true, calling: name ?? phone }),
  send_sms: ({ phone }) => ({ ok: true, opened: 'sms', phone }),
  send_whatsapp: ({ phone }) => ({ ok: true, opened: 'whatsapp', phone }),
  get_location: () => ({ lat: 43.238, lng: 76.889, address: 'Алматы, проспект Абая 10' }),
  navigate_to: ({ destination, lat, lng }) => ({ ok: true, opened: '2gis', navigating_to: destination, lat, lng }),
  search_nearby: ({ query }) => ({
    ok: true,
    places: [
      { name: 'Coffee Boom', address: 'проспект Абая, 14', distance_m: 180, lat: 43.2385, lng: 76.8902 },
      { name: 'Неделька', address: 'проспект Абая, 22', distance_m: 340, lat: 43.2391, lng: 76.8920 },
      { name: 'Starbucks', address: 'проспект Достык, 44', distance_m: 520, lat: 43.2400, lng: 76.8950 },
    ],
    query,
  }),
  set_alarm: ({ hour, minute }) => ({ ok: true, alarm: `${hour}:${String(minute).padStart(2, '0')}` }),
  set_timer: ({ seconds }) => ({ ok: true, timer_seconds: seconds }),
};

const DEFAULT_SCRIPT = [
  'Привет! Как тебя зовут?',
  'Запомни, что маму зовут Лена и она любит, когда я звоню по вечерам',
  'Позвони маме',
  'Напиши Сергею, что я опоздаю на 10 минут',
  'Петрову',
  'Да, отправляй',
  'Разбуди меня завтра в семь утра',
  'Что ты обо мне помнишь?',
];

async function post(body) {
  const res = await fetch(`${BASE}/api/turn`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(TOKEN ? { 'X-Bianca-Token': TOKEN } : {}) },
    body: JSON.stringify({ sessionId, ...body }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`${res.status}: ${data.error}`);
  return data;
}

function context() {
  return {
    localTime: new Date().toISOString(),
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    coords: { lat: 43.238, lng: 76.889 },
  };
}

async function say(text) {
  console.log(`\n👤 ${text}`);
  const started = Date.now();
  let res = await post({ text, context: context() });
  while (res.type === 'tool_calls') {
    if (res.text) console.log(`🤖 (по ходу) ${res.text}`);
    const toolResults = res.calls.map((c) => {
      const impl = deviceTools[c.name];
      const result = impl ? impl(c.arguments ?? {}) : { error: `Нет инструмента ${c.name}` };
      console.log(`   📱 ${c.name}(${JSON.stringify(c.arguments)}) → ${JSON.stringify(result)}`);
      return { id: c.id, result };
    });
    res = await post({ toolResults, context: context() });
  }
  console.log(`🤖 ${res.text}   [${((Date.now() - started) / 1000).toFixed(1)}с]`);
}

const health = await fetch(`${BASE}/api/health`).then((r) => r.json());
console.log('health:', health);
if (!health.ok) process.exit(1);

const phrases = process.argv.slice(2);
for (const p of phrases.length ? phrases : DEFAULT_SCRIPT) {
  await say(p);
}
