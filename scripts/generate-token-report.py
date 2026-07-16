#!/usr/bin/env python3
"""Sync local Codex token logs and render a 30-day / 24-hour PNG report."""

from __future__ import annotations

import argparse
import json
import sqlite3
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


BACKGROUND = (13, 17, 23)
PANEL = (23, 29, 38)
GRID = (57, 66, 80)
TEXT = (239, 244, 250)
MUTED = (155, 166, 181)
TEAL = (45, 202, 189)
GREEN = (63, 210, 142)
YELLOW = (255, 198, 61)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sessions", type=Path, default=Path.home() / ".codex" / "sessions")
    parser.add_argument("--quota", type=Path)
    parser.add_argument("--completed-periods", action="store_true")
    return parser.parse_args()


def parse_timestamp(value: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    return datetime.fromisoformat(normalized).astimezone()


def sync_sessions(database: Path, sessions: Path, now: datetime) -> None:
    buckets: dict[int, int] = defaultdict(int)
    if sessions.is_dir():
        for file_path in sessions.rglob("*.jsonl"):
            try:
                with file_path.open("r", encoding="utf-8") as handle:
                    for line in handle:
                        if '"token_count"' not in line:
                            continue
                        try:
                            event = json.loads(line)
                            payload = event.get("payload", {})
                            info = payload.get("info", {})
                            last_usage = info.get("last_token_usage", {})
                            if payload.get("type") != "token_count":
                                continue
                            tokens = int(last_usage["total_tokens"])
                            timestamp = parse_timestamp(event["timestamp"])
                        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                            continue
                        if timestamp > now:
                            continue
                        hour = timestamp.replace(minute=0, second=0, microsecond=0)
                        buckets[int(hour.timestamp())] += tokens
            except (OSError, UnicodeError):
                continue

    database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(str(database)) as connection:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS hourly_usage "
            "(hour_start INTEGER PRIMARY KEY NOT NULL, tokens INTEGER NOT NULL CHECK(tokens >= 0))"
        )
        for hour, tokens in buckets.items():
            connection.execute(
                "INSERT INTO hourly_usage(hour_start, tokens) VALUES (?, ?) "
                "ON CONFLICT(hour_start) DO UPDATE SET tokens = excluded.tokens",
                (hour, tokens),
            )

        latest = connection.execute("SELECT MAX(hour_start) FROM hourly_usage").fetchone()[0]
        if buckets:
            first_hour = min(min(buckets), latest if latest is not None else min(buckets))
            current_hour = int(now.replace(minute=0, second=0, microsecond=0).timestamp())
            for hour in range(first_hour, current_hour + 1, 3600):
                connection.execute(
                    "INSERT OR IGNORE INTO hourly_usage(hour_start, tokens) VALUES (?, 0)",
                    (hour,),
                )


def load_series(database: Path, now: datetime, completed: bool):
    current_hour = now.replace(minute=0, second=0, microsecond=0)
    end_hour = current_hour - timedelta(hours=1) if completed else current_hour
    hourly_hours = [end_hour - timedelta(hours=offset) for offset in reversed(range(24))]

    end_day = (now.date() - timedelta(days=1)) if completed else now.date()
    daily_days = [end_day - timedelta(days=offset) for offset in reversed(range(30))]

    start_timestamp = int(min(hourly_hours[0], datetime.combine(daily_days[0], datetime.min.time()).astimezone()).timestamp())
    end_timestamp = int((end_hour + timedelta(hours=1)).timestamp())

    with sqlite3.connect(str(database)) as connection:
        rows = connection.execute(
            "SELECT hour_start, tokens FROM hourly_usage WHERE hour_start >= ? ORDER BY hour_start",
            (start_timestamp,),
        ).fetchall()

    by_hour = {int(timestamp): int(tokens) for timestamp, tokens in rows}
    hourly_values = [by_hour.get(int(hour.timestamp()), 0) for hour in hourly_hours]
    daily_totals = defaultdict(int)
    for timestamp, tokens in rows:
        if timestamp >= end_timestamp and completed:
            continue
        day = datetime.fromtimestamp(timestamp).astimezone().date()
        daily_totals[day] += int(tokens)
    daily_values = [daily_totals.get(day, 0) for day in daily_days]
    return daily_days, daily_values, hourly_hours, hourly_values


def load_quota(path: Path, now: datetime):
    try:
        snapshot = json.loads(path.read_text(encoding="utf-8"))
        token_percent = max(0.0, min(100.0, float(snapshot["remainingPercent"])))
        reset_at = datetime.fromtimestamp(float(snapshot["resetAt"])).astimezone()
        duration_seconds = float(snapshot["durationMinutes"]) * 60
        remaining_seconds = max(0.0, (reset_at - now).total_seconds())
        time_percent = max(0.0, min(100.0, remaining_seconds / duration_seconds * 100))
        return token_percent, time_percent, compact_duration(remaining_seconds)
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError, ZeroDivisionError):
        return None


def compact_duration(seconds: float) -> str:
    if seconds >= 86_400:
        days = int(seconds // 86_400)
        hours = (seconds - days * 86_400) / 3_600
        return f"{days}d{hours:.1f}h"
    if seconds >= 3_600:
        return f"{seconds / 3_600:.1f}h"
    return f"{int(max(0, seconds) / 60 + 0.999):d}m"


def font(size: int, bold: bool = False):
    candidates = [
        Path("/System/Library/Fonts/Hiragino Sans GB.ttc"),
        Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf"),
        Path("/System/Library/Fonts/SFNS.ttf"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size, index=1 if bold and candidate.suffix == ".ttc" else 0)
    return ImageFont.load_default()


def format_m(tokens: int) -> str:
    value = tokens / 1_000_000
    if value >= 100:
        return f"{value:.0f}M"
    if value >= 10:
        return f"{value:.1f}M"
    return f"{value:.2f}M"


def rounded_rect(draw: ImageDraw.ImageDraw, box, radius: float, fill) -> None:
    left, top, right, bottom = [int(round(value)) for value in box]
    radius = int(min(radius, (right - left) / 2, (bottom - top) / 2))
    if radius <= 0:
        draw.rectangle((left, top, right, bottom), fill=fill)
        return
    draw.rectangle((left + radius, top, right - radius, bottom), fill=fill)
    draw.rectangle((left, top + radius, right, bottom - radius), fill=fill)
    draw.pieslice((left, top, left + radius * 2, top + radius * 2), 180, 270, fill=fill)
    draw.pieslice((right - radius * 2, top, right, top + radius * 2), 270, 360, fill=fill)
    draw.pieslice((left, bottom - radius * 2, left + radius * 2, bottom), 90, 180, fill=fill)
    draw.pieslice((right - radius * 2, bottom - radius * 2, right, bottom), 0, 90, fill=fill)


def draw_chart(draw: ImageDraw.ImageDraw, box, title, labels, values, color, label_step):
    x, y, width, height = box
    rounded_rect(draw, (x, y, x + width, y + height), radius=18, fill=PANEL)
    draw.text((x + 24, y + 18), title, font=font(24, True), fill=TEXT)

    plot_left = x + 76
    plot_right = x + width - 24
    plot_top = y + 66
    plot_bottom = y + height - 52
    plot_height = plot_bottom - plot_top
    maximum = max(max(values, default=0), 1)

    for step in range(5):
        ratio = step / 4
        grid_y = plot_bottom - ratio * plot_height
        draw.line((plot_left, grid_y, plot_right, grid_y), fill=GRID, width=1)
        value = int(maximum * ratio)
        label = format_m(value)
        label_width, label_height = draw.textsize(label, font=font(14))
        draw.text((plot_left - label_width - 12, grid_y - label_height / 2), label, font=font(14), fill=MUTED)

    count = len(values)
    slot = (plot_right - plot_left) / max(count, 1)
    bar_width = max(4, slot * 0.58)
    for index, value in enumerate(values):
        bar_height = max(2, value / maximum * plot_height)
        center_x = plot_left + slot * (index + 0.5)
        bar_box = (center_x - bar_width / 2, plot_bottom - bar_height, center_x + bar_width / 2, plot_bottom)
        rounded_rect(draw, bar_box, radius=min(4, bar_width / 2), fill=YELLOW if index == count - 1 else color)
        if index % label_step == 0 or index == count - 1:
            text = labels[index]
            text_width, _ = draw.textsize(text, font=font(13))
            draw.text((center_x - text_width / 2, plot_bottom + 12), text, font=font(13), fill=MUTED)


def draw_progress(draw: ImageDraw.ImageDraw, box, percent, text, color):
    x, y, width, height = box
    rounded_rect(draw, (x, y, x + width, y + height), radius=10, fill=PANEL)
    inner = (x + 4, y + 4, x + width - 4, y + height - 4)
    rounded_rect(draw, inner, radius=7, fill=GRID)
    ratio = max(0.0, min(100.0, percent)) / 100
    if ratio > 0:
        rounded_rect(
            draw,
            (inner[0], inner[1], inner[0] + (inner[2] - inner[0]) * ratio, inner[3]),
            radius=7,
            fill=color,
        )
    text_width, text_height = draw.textsize(text, font=font(18, True))
    draw.text((x + (width - text_width) / 2, y + (height - text_height) / 2 - 1), text, font=font(18, True), fill=TEXT)


def render(output: Path, daily_days, daily_values, hourly_hours, hourly_values, quota, now: datetime) -> None:
    image = Image.new("RGB", (1400, 900), BACKGROUND)
    draw = ImageDraw.Draw(image)

    draw.text((48, 34), "Codex Token 使用日报", font=font(34, True), fill=TEXT)
    draw.text((48, 82), now.strftime("生成时间 %Y-%m-%d %H:%M %Z"), font=font(16), fill=MUTED)
    summary = f"近30日 {format_m(sum(daily_values))}    近24h {format_m(sum(hourly_values))}"
    summary_width, _ = draw.textsize(summary, font=font(24, True))
    draw.text((1352 - summary_width, 48), summary, font=font(24, True), fill=TEXT)

    if quota:
        token_percent, time_percent, remaining_text = quota
        draw_progress(draw, (48, 120, 640, 48), token_percent, f"Token 剩余 {token_percent:.0f}%", TEAL)
        draw_progress(draw, (712, 120, 640, 48), time_percent, f"Time 剩余 {time_percent:.0f}% · {remaining_text}", GREEN)
    else:
        draw_progress(draw, (48, 120, 640, 48), 0, "Token 剩余 --", TEAL)
        draw_progress(draw, (712, 120, 640, 48), 0, "Time 剩余 --", GREEN)

    draw_chart(
        draw,
        (48, 192, 1304, 300),
        "近30天 · 每日用量",
        [day.strftime("%m-%d") for day in daily_days],
        daily_values,
        TEAL,
        5,
    )
    draw_chart(
        draw,
        (48, 524, 1304, 300),
        "近24小时 · 每小时用量",
        [hour.strftime("%H:00") for hour in hourly_hours],
        hourly_values,
        GREEN,
        4,
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(str(output), format="PNG", optimize=True)


def main() -> int:
    args = parse_args()
    now = datetime.now().astimezone()
    sync_sessions(args.database, args.sessions, now)
    series = load_series(args.database, now, args.completed_periods)
    quota_path = args.quota or args.database.with_name("quota-status.json")
    quota = load_quota(quota_path, now)
    render(args.output, *series, quota, now)
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
