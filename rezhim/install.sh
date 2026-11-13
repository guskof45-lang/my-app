#!/bin/bash
# Установка бота «Мой режим» на VPS (Ubuntu)
set -e
if [ "$(id -u)" -ne 0 ]; then echo "Запусти от root (или через sudo)"; exit 1; fi

echo "=== Установка бота «Мой режим» ==="
read -r -p "1) Вставь ТОКЕН бота от BotFather и нажми Enter: " TOKEN
read -r -p "2) Вставь ССЫЛКУ на мини-апп (https://...) и нажми Enter: " URL
if [ -z "$TOKEN" ] || [ -z "$URL" ]; then echo "Токен и ссылка обязательны"; exit 1; fi

mkdir -p /opt/rezhim
cd /opt/rezhim

echo "Ставлю Python-окружение (1-2 минуты)..."
apt-get install -y python3-venv >/dev/null 2>&1 || true
[ -d venv ] || python3 -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q "aiogram>=3.7,<4"

printf 'BOT_TOKEN=%s\nAPP_URL=%s\n' "$TOKEN" "$URL" > .env
chmod 600 .env

cat > bot.py <<'PYEOF'
"""Бот «Мой режим»: напоминает о главных делах дня и открывает мини-апп.

Работает только для одного человека: того, кто первым нажал /start.
Время: Ташкент (UTC+5).
"""
import asyncio
import json
import logging
import os
from datetime import datetime, timedelta, timezone

from aiogram import Bot, Dispatcher
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    BotCommand,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    MenuButtonWebApp,
    Message,
    WebAppInfo,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

TOKEN = os.environ["BOT_TOKEN"]
APP_URL = os.environ["APP_URL"]
TZ = timezone(timedelta(hours=5))  # Узбекистан, без перехода на летнее время
DATA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data.json")

# ---------- напоминания ----------
WEEK = {
    "07:30": "☀️ <b>Подъём!</b>\nПервые 30 минут без телефона: вода, умыться, одеться.\nСейчас просто закрой это сообщение 🙂",
    "08:00": "📝 <b>Завтрак и 3 задачи.</b>\nОткрой «Мой режим» и запиши 3 главные задачи на сегодня.",
    "08:30": "🚗 <b>Права: 1 час теории.</b>\nТелефон в сторону, только билеты. Не забудь отметить, сколько решил.",
    "09:45": "🛍 <b>Товар и заказы, 2 часа.</b>\nPinduoduo, новые позиции, заказы. Клиентам пока отвечает бот.",
    "13:00": "📸 <b>Контент, 1.5 часа.</b>\nФото, посты в каналы, сторис.",
    "19:30": "🎮 <b>Время отдыха!</b>\n2 часа игр и видео без чувства вины. Нажми «Начать отдых» в приложении.",
    "21:30": "⏹ <b>Отдых закончился.</b>\nПроверь Телеграм и подведи итоги: оцени день и запиши задачи на завтра.",
    "23:00": "🌙 <b>Через 30 минут сон.</b>\nУбери телефон на зарядку подальше от кровати. Завтра подъём в 7:30.",
}
DEEP_PROJECTS = "💻 <b>Проекты, 2 часа.</b>\nБоты, Drip Store. Одна задача, до конца."
DEEP_PROMO = "📣 <b>Продвижение и реклама, 2 часа.</b>\nИщем новых клиентов для DripUz."
SUNDAY = {
    "09:00": "😌 <b>Сегодня выходной!</b>\nОтдыхай. Телеграм проверь только в 12:00 и 19:00.",
    "19:15": "🗓 <b>План на неделю, 45 минут.</b>\nЧто главное по магазину и правам на эту неделю?",
    "23:00": "🌙 <b>Через 30 минут сон.</b>\nЗавтра понедельник, подъём в 7:30.",
}

PLAN_WEEK = [
    ("07:30", "Подъём без телефона"), ("08:00", "Завтрак и 3 задачи"),
    ("08:30", "Права: теория"), ("09:30", "Телеграм, проверка 1"),
    ("09:45", "Товар и заказы"), ("11:45", "Обед и отдых"),
    ("12:45", "Телеграм, проверка 2"), ("13:00", "Контент"),
    ("14:30", "Прогулка или зарядка"), ("15:00", "{deep}"),
    ("17:00", "Телеграм, проверка 3"), ("17:15", "Запас"),
    ("19:00", "Ужин"), ("19:30", "Игры и видео"),
    ("21:30", "Телеграм 4 и итоги дня"), ("22:00", "Без экранов"),
    ("23:30", "Сон"),
]
PLAN_SUNDAY = [
    ("09:00", "Спокойный подъём"), ("09:30", "Свободное утро"),
    ("12:00", "Телеграм, проверка 1"), ("12:15", "Выходной"),
    ("19:00", "Телеграм, проверка 2"), ("19:15", "План на неделю"),
    ("20:00", "Отдых, игры, кино"), ("22:00", "Без экранов"), ("23:30", "Сон"),
]


def is_project_day(dt: datetime) -> bool:
    return dt.weekday() in (0, 2, 4)  # Пн, Ср, Пт


def reminders_for(dt: datetime) -> dict:
    if dt.weekday() == 6:
        return SUNDAY
    r = dict(WEEK)
    r["15:00"] = DEEP_PROJECTS if is_project_day(dt) else DEEP_PROMO
    return r


def plan_text(dt: datetime) -> str:
    if dt.weekday() == 6:
        rows, title = PLAN_SUNDAY, "Воскресенье, выходной"
    else:
        deep = "Проекты" if is_project_day(dt) else "Продвижение и реклама"
        rows = [(t, n.replace("{deep}", deep)) for t, n in PLAN_WEEK]
        title = "План на сегодня"
    now_hm = dt.strftime("%H:%M")
    lines = [f"<b>{title}</b>"]
    for i, (t, n) in enumerate(rows):
        nxt = rows[i + 1][0] if i + 1 < len(rows) else "99:99"
        mark = "👉 " if t <= now_hm < nxt else ""
        lines.append(f"{mark}<code>{t}</code>  {n}")
    return "\n".join(lines)


# ---------- данные ----------
def load() -> dict:
    try:
        with open(DATA_FILE, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        d = {}
    d.setdefault("owner", None)
    d.setdefault("on", True)
    d.setdefault("pause", "")
    return d


def save(d: dict) -> None:
    tmp = DATA_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, DATA_FILE)


def kb() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="📱 Открыть «Мой режим»", web_app=WebAppInfo(url=APP_URL))
    ]])


def today() -> str:
    return datetime.now(TZ).strftime("%Y-%m-%d")


dp = Dispatcher()


async def owner_only(message: Message) -> bool:
    d = load()
    if d["owner"] is None or d["owner"] == message.chat.id:
        return True
    await message.answer("Это личный бот, он работает только для своего хозяина.")
    return False


async def set_menu(bot: Bot, chat_id: int) -> None:
    try:
        await bot.set_chat_menu_button(
            chat_id=chat_id,
            menu_button=MenuButtonWebApp(text="Режим", web_app=WebAppInfo(url=APP_URL)),
        )
    except Exception as e:  # кнопка меню не критична
        logging.warning("menu button: %s", e)


@dp.message(CommandStart())
async def cmd_start(message: Message, bot: Bot):
    if not await owner_only(message):
        return
    d = load()
    if d["owner"] is None:
        d["owner"] = message.chat.id
        save(d)
    await set_menu(bot, message.chat.id)
    await message.answer(
        "Привет! Я твой бот режима 💪\n\n"
        "Буду напоминать о главном: подъём, права, товар, контент, проекты, отдых и сон.\n\n"
        "Команды:\n"
        "/plan — план на сегодня\n"
        "/pause — без напоминаний до конца дня\n"
        "/off — выключить напоминания\n"
        "/on — включить снова",
        parse_mode="HTML",
        reply_markup=kb(),
    )


@dp.message(Command("plan"))
async def cmd_plan(message: Message):
    if not await owner_only(message):
        return
    await message.answer(plan_text(datetime.now(TZ)), parse_mode="HTML", reply_markup=kb())


@dp.message(Command("pause"))
async def cmd_pause(message: Message):
    if not await owner_only(message):
        return
    d = load()
    d["pause"] = today()
    save(d)
    await message.answer("Ок, сегодня больше не напоминаю. Завтра всё как обычно.")


@dp.message(Command("off"))
async def cmd_off(message: Message):
    if not await owner_only(message):
        return
    d = load()
    d["on"] = False
    save(d)
    await message.answer("Напоминания выключены. Включить: /on")


@dp.message(Command("on"))
async def cmd_on(message: Message):
    if not await owner_only(message):
        return
    d = load()
    d["on"] = True
    d["pause"] = ""
    save(d)
    await message.answer("Напоминания включены ✅")


@dp.message()
async def any_text(message: Message):
    if not await owner_only(message):
        return
    await message.answer("Открой приложение кнопкой ниже или напиши /plan", reply_markup=kb())


async def ticker(bot: Bot) -> None:
    sent: set = set()
    while True:
        try:
            now = datetime.now(TZ)
            day, hm = now.strftime("%Y-%m-%d"), now.strftime("%H:%M")
            sent = {s for s in sent if s.startswith(day)}
            tag = f"{day} {hm}"
            text = reminders_for(now).get(hm)
            if text and tag not in sent:
                sent.add(tag)
                d = load()
                if d["owner"] and d["on"] and d["pause"] != day:
                    await bot.send_message(d["owner"], text, parse_mode="HTML", reply_markup=kb())
                    logging.info("sent reminder %s", hm)
        except Exception as e:
            logging.warning("ticker: %s", e)
        await asyncio.sleep(15)


async def main() -> None:
    bot = Bot(TOKEN)
    await bot.set_my_commands([
        BotCommand(command="plan", description="План на сегодня"),
        BotCommand(command="pause", description="Без напоминаний до конца дня"),
        BotCommand(command="off", description="Выключить напоминания"),
        BotCommand(command="on", description="Включить напоминания"),
    ])
    d = load()
    if d["owner"]:
        await set_menu(bot, d["owner"])
    asyncio.create_task(ticker(bot))
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
PYEOF

cat > /etc/systemd/system/rezhim.service <<'UNITEOF'
[Unit]
Description=Moy rezhim reminder bot
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/rezhim
EnvironmentFile=/opt/rezhim/.env
ExecStart=/opt/rezhim/venv/bin/python /opt/rezhim/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable rezhim >/dev/null 2>&1
systemctl restart rezhim
sleep 4
if systemctl is-active --quiet rezhim; then
  echo ""
  echo "✅ Готово! Бот работает."
  echo "Открой своего нового бота в Телеграме и нажми /start"
else
  echo "❌ Бот не запустился. Скопируй текст ниже и отправь Claude:"
  journalctl -u rezhim -n 30 --no-pager
fi
