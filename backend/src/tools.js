// Описание инструментов Бьянки.
// where: 'server' — выполняется прямо в бэкенде (память);
//        'device' — отдаётся телефону, он выполняет и присылает результат.

function fn(name, description, properties = {}, required = []) {
  return {
    type: 'function',
    function: {
      name,
      description,
      parameters: { type: 'object', properties, required },
    },
  };
}

const str = (description) => ({ type: 'string', description });
const int = (description) => ({ type: 'integer', description });
const num = (description) => ({ type: 'number', description });
const bool = (description) => ({ type: 'boolean', description });

export const TOOLS = [
  // ---------- Сервер: долговременная память ----------
  {
    where: 'server',
    schema: fn(
      'remember',
      'Сохранить в долговременную память устойчивый факт о пользователе, его близких, привычках или предпочтениях. ' +
        'Вызывай, когда пользователь просит запомнить или сообщает что-то важное о себе.',
      { fact: str('Факт одним коротким предложением от третьего лица, например: «Маму пользователя зовут Анна»') },
      ['fact'],
    ),
  },
  {
    where: 'server',
    schema: fn(
      'forget',
      'Удалить факт из долговременной памяти, если пользователь просит забыть или факт устарел.',
      { query: str('Слово или фраза, по которой найти факт для удаления') },
      ['query'],
    ),
  },

  // ---------- Телефон ----------
  {
    where: 'device',
    schema: fn(
      'find_contact',
      'Найти контакт в телефонной книге. Обязательно вызывай перед звонком или сообщением, ' +
        'чтобы узнать реальный номер. Передавай точное слово пользователя (например «Мамуля», «Мамочка», «Сергей»).',
      { query: str('Точное имя или обращение, как сказал пользователь (например «Мамуля», «Сергей»)') },
      ['query'],
    ),
  },
  {
    where: 'device',
    schema: fn(
      'make_call',
      'Позвонить по номеру телефона (номер бери из find_contact или из долговременной памяти).',
      { phone: str('Номер телефона'), name: str('Точное имя контакта, которому звоним') },
      ['phone', 'name'],
    ),
  },
  {
    where: 'device',
    schema: fn(
      'send_sms',
      'Открыть отправку SMS с готовым текстом. Вызывай только после того, как пользователь подтвердил текст.',
      { phone: str('Номер телефона'), text: str('Текст сообщения'), name: str('Имя контакта') },
      ['phone', 'text'],
    ),
  },
  {
    where: 'device',
    schema: fn(
      'send_whatsapp',
      'Подготовить сообщение WhatsApp. Первый вызов создаёт draft и возвращает confirmation_required. ' +
        'После явного подтверждения пользователя повтори вызов с неизменными phone, name и text: ' +
        'телефон вернёт whatsapp_composer_ready и откроет чат, но не отправит сообщение автоматически.',
      { phone: str('Номер телефона'), text: str('Текст сообщения'), name: str('Имя контакта') },
      ['phone', 'text'],
    ),
  },
  {
    where: 'device',
    schema: fn('get_location', 'Узнать текущее местоположение пользователя: координаты и адрес.'),
  },
  {
    where: 'device',
    schema: fn(
      'navigate_to',
      'Построить маршрут или открыть место в 2ГИС (навигаторе). ' +
        'Если известны координаты места из search_nearby — обязательно передай lat и lng.',
      {
        destination: str('Название места или адрес'),
        lat: num('Широта точки назначения (если известна из search_nearby)'),
        lng: num('Долгота точки назначения (если известна из search_nearby)'),
      },
      ['destination'],
    ),
  },
  {
    where: 'device',
    schema: fn(
      'search_nearby',
      'Найти ближайшие места рядом с пользователем (кофейни, кафе, заправки, аптеки, магазины, банкоматы, автомойки и т.п.) ' +
        'и получить список реальных заведений с названиями, адресами, координатами и расстоянием в метрах. ' +
        'Передавай open_map=true ТОЛЬКО если пользователь прямо попросил сразу открыть карту или 2ГИС.',
      {
        query: str('Что искать, например «кофейня», «заправка», «аптека»'),
        open_map: bool('true — сразу открыть поиск в 2ГИС; false (по умолчанию) — узнать места и назвать их голосом'),
      },
      ['query'],
    ),
  },
  {
    where: 'device',
    schema: fn(
      'set_alarm',
      'Поставить будильник.',
      { hour: int('Час, 0-23'), minute: int('Минуты, 0-59'), label: str('Подпись будильника') },
      ['hour', 'minute'],
    ),
  },
  {
    where: 'device',
    schema: fn(
      'set_timer',
      'Запустить таймер.',
      { seconds: int('Длительность в секундах'), label: str('Подпись таймера') },
      ['seconds'],
    ),
  },
];

export const TOOL_SCHEMAS = TOOLS.map((t) => t.schema);

const whereByName = new Map(TOOLS.map((t) => [t.schema.function.name, t.where]));

export function toolLocation(name) {
  return whereByName.get(name) ?? null;
}
