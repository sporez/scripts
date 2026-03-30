#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CATEGORY_ALIASES = {
    "mac": "macs",
    "macs": "macs",
    "iphone": "iphones",
    "iphones": "iphones",
    "ipad": "ipads",
    "ipads": "ipads",
    "watch": "watches",
    "watches": "watches",
    "airpod": "airpods",
    "airpods": "airpods",
    "appletv": "appletvs",
    "appletvs": "appletvs",
    "homepod": "homepods",
    "homepods": "homepods",
    "accessory": "accessories",
    "accessories": "accessories",
    "clearance": "clearance",
}


DEFAULT_POLL_INTERVAL_SECONDS = 300
DEFAULT_STATE_FILE = "state.json"
MAX_SEEN_URLS_PER_WATCHER = 5000


@dataclass
class PushoverConfig:
    token: str
    user: str
    device: str = ""
    priority: int = 0
    sound: str = ""


@dataclass
class WatcherConfig:
    watcher_id: str
    enabled: bool
    store: str
    category: str
    name_contains_all: list[str] = field(default_factory=list)
    name_contains_any: list[str] = field(default_factory=list)
    exclude_contains: list[str] = field(default_factory=list)
    name_regex: str = ""
    min_price: float | None = None
    max_price: float | None = None
    min_saving: float = 0.0
    min_saving_percentage: float = 0.0
    max_previous_price: float | None = None
    model_in: set[str] = field(default_factory=set)
    alert_title: str = ""
    regex_obj: re.Pattern[str] | None = None

    def __post_init__(self) -> None:
        if self.min_price is not None and self.max_price is not None:
            if self.min_price > self.max_price:
                raise ValueError(
                    f"Watcher '{self.watcher_id}' has min_price > max_price"
                )

        if self.name_regex:
            try:
                self.regex_obj = re.compile(self.name_regex, re.IGNORECASE)
            except re.error as exc:
                raise ValueError(
                    f"Watcher '{self.watcher_id}' has invalid name_regex: {exc}"
                ) from exc


@dataclass
class AppConfig:
    poll_interval_seconds: int
    state_file: str
    pushover: PushoverConfig | None
    watchers: list[WatcherConfig]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Monitor Apple refurbished store and send Pushover alerts"
    )

    def add_config_argument(p: argparse.ArgumentParser) -> None:
        p.add_argument(
            "--config",
            default="watchers.toml",
            help="Path to config TOML file (default: watchers.toml)",
        )

    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Run continuously")
    add_config_argument(run_parser)
    run_parser.add_argument(
        "--interval",
        type=int,
        default=None,
        help="Override polling interval in seconds",
    )
    run_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not send alerts or update state",
    )

    interactive_parser = subparsers.add_parser(
        "interactive",
        help="Launch interactive menu UI (mLog-style)",
    )
    add_config_argument(interactive_parser)
    interactive_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Default to dry-run for checks",
    )
    interactive_parser.add_argument(
        "--interval",
        type=int,
        default=None,
        help="Default interval for watch mode (seconds)",
    )

    tui_parser = subparsers.add_parser("tui", help="Run terminal dashboard")
    add_config_argument(tui_parser)
    tui_parser.add_argument(
        "--interval",
        type=int,
        default=None,
        help="Override polling interval in seconds",
    )
    tui_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not send alerts or update state",
    )

    check_parser = subparsers.add_parser("check", help="Run one check cycle")
    add_config_argument(check_parser)
    check_parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not send alerts or update state",
    )

    list_parser = subparsers.add_parser(
        "list-watchers", help="List configured watchers"
    )
    add_config_argument(list_parser)

    test_parser = subparsers.add_parser(
        "test-pushover", help="Send a test Pushover message"
    )
    add_config_argument(test_parser)
    test_parser.add_argument(
        "--message",
        default="Apple refurb monitor test notification",
        help="Test message body",
    )

    reset_parser = subparsers.add_parser(
        "reset-seen",
        help="Clear dedupe state for all watchers or one watcher",
    )
    add_config_argument(reset_parser)
    reset_parser.add_argument(
        "--watcher-id",
        default="",
        help="Only clear state for this watcher ID",
    )

    return parser.parse_args()


def _to_str_list(raw: Any, field_name: str, watcher_id: str) -> list[str]:
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError(
            f"Watcher '{watcher_id}' field '{field_name}' must be a list"
        )
    values: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            raise ValueError(
                f"Watcher '{watcher_id}' field '{field_name}' items must be strings"
            )
        text = item.strip()
        if text:
            values.append(text)
    return values


def _to_optional_float(
    raw: Any, field_name: str, watcher_id: str
) -> float | None:
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    raise ValueError(f"Watcher '{watcher_id}' field '{field_name}' must be numeric")


def _to_float(raw: Any, field_name: str, watcher_id: str, default: float) -> float:
    if raw is None:
        return default
    if isinstance(raw, (int, float)):
        return float(raw)
    raise ValueError(f"Watcher '{watcher_id}' field '{field_name}' must be numeric")


def normalize_category(value: str) -> str:
    key = value.strip().lower()
    if key not in CATEGORY_ALIASES:
        options = ", ".join(sorted(set(CATEGORY_ALIASES.values())))
        raise ValueError(f"Unsupported category '{value}'. Supported: {options}")
    return CATEGORY_ALIASES[key]


def load_config(config_path: Path) -> AppConfig:
    if not config_path.exists():
        raise FileNotFoundError(f"Config not found: {config_path}")

    with config_path.open("rb") as f:
        raw = tomllib.load(f)

    if not isinstance(raw, dict):
        raise ValueError("Config root must be a TOML table")

    poll_interval_seconds = raw.get("poll_interval_seconds", DEFAULT_POLL_INTERVAL_SECONDS)
    if not isinstance(poll_interval_seconds, int) or poll_interval_seconds <= 0:
        raise ValueError("poll_interval_seconds must be a positive integer")

    state_file = raw.get("state_file", DEFAULT_STATE_FILE)
    if not isinstance(state_file, str) or not state_file.strip():
        raise ValueError("state_file must be a non-empty string")

    pushover = None
    raw_pushover = raw.get("pushover")
    if raw_pushover is not None:
        if not isinstance(raw_pushover, dict):
            raise ValueError("[pushover] must be a TOML table")
        token = raw_pushover.get("token", "")
        user = raw_pushover.get("user", "")
        if not isinstance(token, str) or not token.strip():
            raise ValueError("[pushover].token is required")
        if not isinstance(user, str) or not user.strip():
            raise ValueError("[pushover].user is required")
        device = raw_pushover.get("device", "")
        priority = raw_pushover.get("priority", 0)
        sound = raw_pushover.get("sound", "")

        if not isinstance(device, str):
            raise ValueError("[pushover].device must be a string")
        if not isinstance(priority, int):
            raise ValueError("[pushover].priority must be an integer")
        if not isinstance(sound, str):
            raise ValueError("[pushover].sound must be a string")

        pushover = PushoverConfig(
            token=token.strip(),
            user=user.strip(),
            device=device.strip(),
            priority=priority,
            sound=sound.strip(),
        )

    raw_watchers = raw.get("watchers", [])
    if not isinstance(raw_watchers, list) or not raw_watchers:
        raise ValueError("At least one [[watchers]] entry is required")

    watchers: list[WatcherConfig] = []
    seen_ids: set[str] = set()

    for idx, entry in enumerate(raw_watchers, start=1):
        if not isinstance(entry, dict):
            raise ValueError(f"watchers entry #{idx} must be a TOML table")

        watcher_id = entry.get("id", "")
        if not isinstance(watcher_id, str) or not watcher_id.strip():
            raise ValueError(f"watchers entry #{idx} requires a non-empty 'id'")
        watcher_id = watcher_id.strip()

        if watcher_id in seen_ids:
            raise ValueError(f"Duplicate watcher id: '{watcher_id}'")
        seen_ids.add(watcher_id)

        enabled = entry.get("enabled", True)
        if not isinstance(enabled, bool):
            raise ValueError(f"Watcher '{watcher_id}' field 'enabled' must be bool")

        store = entry.get("store", "us")
        if not isinstance(store, str) or not store.strip():
            raise ValueError(f"Watcher '{watcher_id}' field 'store' must be a string")

        category_raw = entry.get("category", "macs")
        if not isinstance(category_raw, str) or not category_raw.strip():
            raise ValueError(
                f"Watcher '{watcher_id}' field 'category' must be a string"
            )
        category = normalize_category(category_raw)

        model_in = set(s.upper() for s in _to_str_list(entry.get("model_in"), "model_in", watcher_id))

        alert_title = entry.get("alert_title", "")
        if not isinstance(alert_title, str):
            raise ValueError(f"Watcher '{watcher_id}' field 'alert_title' must be str")

        watcher = WatcherConfig(
            watcher_id=watcher_id,
            enabled=enabled,
            store=store.strip().lower(),
            category=category,
            name_contains_all=_to_str_list(
                entry.get("name_contains_all"), "name_contains_all", watcher_id
            ),
            name_contains_any=_to_str_list(
                entry.get("name_contains_any"), "name_contains_any", watcher_id
            ),
            exclude_contains=_to_str_list(
                entry.get("exclude_contains"), "exclude_contains", watcher_id
            ),
            name_regex=entry.get("name_regex", "") or "",
            min_price=_to_optional_float(entry.get("min_price"), "min_price", watcher_id),
            max_price=_to_optional_float(entry.get("max_price"), "max_price", watcher_id),
            min_saving=_to_float(entry.get("min_saving"), "min_saving", watcher_id, 0.0),
            min_saving_percentage=_to_float(
                entry.get("min_saving_percentage"),
                "min_saving_percentage",
                watcher_id,
                0.0,
            ),
            max_previous_price=_to_optional_float(
                entry.get("max_previous_price"), "max_previous_price", watcher_id
            ),
            model_in=model_in,
            alert_title=alert_title.strip(),
        )

        watchers.append(watcher)

    return AppConfig(
        poll_interval_seconds=poll_interval_seconds,
        state_file=state_file.strip(),
        pushover=pushover,
        watchers=watchers,
    )


def load_state(state_path: Path) -> dict[str, Any]:
    if not state_path.exists():
        return {"watchers": {}}

    try:
        with state_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            data.setdefault("watchers", {})
            if not isinstance(data["watchers"], dict):
                data["watchers"] = {}
            return data
    except json.JSONDecodeError:
        pass

    return {"watchers": {}}


def save_state(state_path: Path, state: dict[str, Any]) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    with state_path.open("w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)


def get_watcher_state(state: dict[str, Any], watcher_id: str) -> dict[str, Any]:
    watchers = state.setdefault("watchers", {})
    if watcher_id not in watchers or not isinstance(watchers[watcher_id], dict):
        watchers[watcher_id] = {}
    watcher_state = watchers[watcher_id]
    seen = watcher_state.get("seen_urls")
    if not isinstance(seen, list):
        watcher_state["seen_urls"] = []
    return watcher_state


def fetch_products(watcher: WatcherConfig) -> list[Any]:
    try:
        import importlib

        refurbished_module = importlib.import_module("refurbished")
        Store = getattr(refurbished_module, "Store")
        ProductNotFoundError = getattr(refurbished_module, "ProductNotFoundError")
    except ImportError as exc:
        raise RuntimeError(
            "Missing dependency 'refurbished'. Install with: pip install refurbished"
        ) from exc

    store = Store(watcher.store)
    getter_name = f"get_{watcher.category}"
    getter = getattr(store, getter_name, None)
    if getter is None:
        raise RuntimeError(
            f"Category '{watcher.category}' is not supported by refurbished library"
        )

    kwargs: dict[str, Any] = {}
    if watcher.min_saving > 0:
        kwargs["min_saving"] = watcher.min_saving
    if watcher.min_saving_percentage > 0:
        kwargs["min_saving_percentage"] = watcher.min_saving_percentage
    if watcher.max_price is not None:
        kwargs["max_price"] = watcher.max_price
    if watcher.max_previous_price is not None:
        kwargs["max_previous_price"] = watcher.max_previous_price

    try:
        return list(getter(**kwargs))
    except ProductNotFoundError as exc:
        raise RuntimeError(str(exc)) from exc


def product_matches_watcher(product: Any, watcher: WatcherConfig) -> bool:
    product_name = str(getattr(product, "name", ""))
    name_lower = product_name.lower()

    for term in watcher.name_contains_all:
        if term.lower() not in name_lower:
            return False

    if watcher.name_contains_any:
        if not any(term.lower() in name_lower for term in watcher.name_contains_any):
            return False

    for term in watcher.exclude_contains:
        if term.lower() in name_lower:
            return False

    if watcher.regex_obj is not None and watcher.regex_obj.search(product_name) is None:
        return False

    product_model = str(getattr(product, "model", "") or "").upper()
    if watcher.model_in and product_model not in watcher.model_in:
        return False

    price = float(getattr(product, "price", 0) or 0)
    if watcher.min_price is not None and price < watcher.min_price:
        return False
    if watcher.max_price is not None and price > watcher.max_price:
        return False

    savings_price = float(getattr(product, "savings_price", 0) or 0)
    if savings_price < watcher.min_saving:
        return False

    savings_pct = float(getattr(product, "saving_percentage", 0) or 0) * 100
    if savings_pct < watcher.min_saving_percentage:
        return False

    return True


def build_alert_title(watcher: WatcherConfig) -> str:
    if watcher.alert_title:
        return watcher.alert_title
    return f"Apple Refurb Match: {watcher.watcher_id}"


def build_alert_message(watcher: WatcherConfig, product: Any) -> str:
    price = float(getattr(product, "price", 0) or 0)
    previous_price = float(getattr(product, "previous_price", 0) or 0)
    savings_price = float(getattr(product, "savings_price", 0) or 0)
    savings_pct = float(getattr(product, "saving_percentage", 0) or 0) * 100
    url = str(getattr(product, "url", ""))
    model = str(getattr(product, "model", "") or "-")

    lines = [
        str(getattr(product, "name", "(unknown product)")),
        f"Now ${price:,.2f} | Was ${previous_price:,.2f} | Save ${savings_price:,.2f} ({savings_pct:.0f}%)",
        f"Model: {model} | Store: {watcher.store.upper()} | Category: {watcher.category}",
        url,
    ]
    message = "\n".join(lines)
    if len(message) > 1024:
        message = message[:1021] + "..."
    return message


def send_pushover(
    pushover: PushoverConfig, title: str, message: str, url: str = ""
) -> str:
    payload: dict[str, str] = {
        "token": pushover.token,
        "user": pushover.user,
        "title": title[:250],
        "message": message[:1024],
        "priority": str(pushover.priority),
    }
    if pushover.device:
        payload["device"] = pushover.device
    if pushover.sound:
        payload["sound"] = pushover.sound
    if url:
        payload["url"] = url
        payload["url_title"] = "Open product"

    encoded = urllib.parse.urlencode(payload).encode("utf-8")
    request = urllib.request.Request(
        "https://api.pushover.net/1/messages.json",
        data=encoded,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Pushover HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Pushover request failed: {exc}") from exc

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Pushover returned non-JSON response: {body}") from exc

    if parsed.get("status") != 1:
        raise RuntimeError(f"Pushover rejected message: {parsed}")

    return str(parsed.get("request", ""))


def run_cycle(
    config: AppConfig,
    state_path: Path,
    dry_run: bool,
    verbose: bool = True,
) -> dict[str, Any]:
    state = load_state(state_path)

    total_matches = 0
    total_new = 0
    cycle_results: list[dict[str, Any]] = []

    def vlog(message: str) -> None:
        if verbose:
            log(message)

    for watcher in config.watchers:
        watcher_result: dict[str, Any] = {
            "watcher_id": watcher.watcher_id,
            "store": watcher.store,
            "category": watcher.category,
            "enabled": watcher.enabled,
            "status": "disabled" if not watcher.enabled else "ok",
            "error": "",
            "matched_count": 0,
            "new_count": 0,
            "alerts_sent": 0,
            "checked_at": "",
        }

        if not watcher.enabled:
            watcher_state = get_watcher_state(state, watcher.watcher_id)
            watcher_state["last_checked"] = now_iso()
            watcher_state["last_match_count"] = 0
            watcher_state["last_new_count"] = 0
            watcher_state["last_error"] = ""
            watcher_result["checked_at"] = str(watcher_state["last_checked"])
            cycle_results.append(watcher_result)
            continue

        vlog(
            f"Checking watcher '{watcher.watcher_id}' "
            f"({watcher.store}/{watcher.category})"
        )

        try:
            products = fetch_products(watcher)
        except Exception as exc:
            watcher_result["status"] = "fetch_error"
            watcher_result["error"] = str(exc)

            watcher_state = get_watcher_state(state, watcher.watcher_id)
            watcher_state["last_checked"] = now_iso()
            watcher_state["last_match_count"] = 0
            watcher_state["last_new_count"] = 0
            watcher_state["last_error"] = str(exc)
            watcher_result["checked_at"] = str(watcher_state["last_checked"])

            vlog(f"Watcher '{watcher.watcher_id}' fetch failed: {exc}")
            cycle_results.append(watcher_result)
            continue

        matched_products = [
            product
            for product in products
            if product_matches_watcher(product, watcher)
        ]
        total_matches += len(matched_products)

        watcher_state = get_watcher_state(state, watcher.watcher_id)
        seen_urls = [
            str(url)
            for url in watcher_state.get("seen_urls", [])
            if isinstance(url, str)
        ]
        seen_url_set = set(seen_urls)

        new_products = [
            product
            for product in matched_products
            if str(getattr(product, "url", "")) not in seen_url_set
        ]
        total_new += len(new_products)
        watcher_result["matched_count"] = len(matched_products)
        watcher_result["new_count"] = len(new_products)

        if new_products:
            vlog(
                f"Watcher '{watcher.watcher_id}' found "
                f"{len(new_products)} new match(es)"
            )
        else:
            vlog(f"Watcher '{watcher.watcher_id}' found no new matches")

        if not dry_run:
            for product in new_products:
                product_url = str(getattr(product, "url", ""))
                if not product_url:
                    continue

                if config.pushover is None:
                    raise RuntimeError(
                        "[pushover] config is required unless using --dry-run"
                    )

                title = build_alert_title(watcher)
                message = build_alert_message(watcher, product)
                try:
                    request_id = send_pushover(
                        config.pushover,
                        title=title,
                        message=message,
                        url=product_url,
                    )
                    seen_urls.append(product_url)
                    seen_url_set.add(product_url)
                    watcher_result["alerts_sent"] = int(
                        watcher_result["alerts_sent"]
                    ) + 1
                    vlog(
                        f"Alert sent for watcher '{watcher.watcher_id}' "
                        f"(request {request_id})"
                    )
                except Exception as exc:
                    watcher_result["status"] = "alert_error"
                    watcher_result["error"] = str(exc)
                    vlog(
                        f"Failed to send alert for watcher '{watcher.watcher_id}': {exc}"
                    )
        elif new_products:
            for product in new_products:
                product_name = str(getattr(product, "name", "(unknown)"))
                vlog(f"[dry-run] Would alert: {product_name}")

        watcher_state["last_checked"] = now_iso()
        watcher_state["last_match_count"] = len(matched_products)
        watcher_state["last_new_count"] = len(new_products)
        watcher_state["last_error"] = str(watcher_result["error"])
        watcher_result["checked_at"] = str(watcher_state["last_checked"])
        if not dry_run:
            watcher_state["seen_urls"] = seen_urls[-MAX_SEEN_URLS_PER_WATCHER:]

        cycle_results.append(watcher_result)

    if not dry_run:
        save_state(state_path, state)

    vlog(f"Cycle complete. Total matches: {total_matches}. New matches: {total_new}.")
    return {
        "ran_at": now_iso(),
        "total_matches": total_matches,
        "total_new": total_new,
        "watchers": cycle_results,
    }


def _trim(value: str, max_len: int) -> str:
    if max_len <= 0:
        return ""
    if len(value) <= max_len:
        return value
    if max_len == 1:
        return value[:1]
    return value[: max_len - 1] + "~"


def _cycle_to_rows(cycle: dict[str, Any]) -> list[dict[str, Any]]:
    watchers = cycle.get("watchers", [])
    if not isinstance(watchers, list):
        return []
    rows: list[dict[str, Any]] = []
    for item in watchers:
        if isinstance(item, dict):
            rows.append(item)
    return rows


def _format_checked_at(value: str) -> str:
    if not value:
        return "-"
    return value.replace("T", " ")[:19]


def _status_label(status_raw: str) -> str:
    if status_raw == "ok":
        return "OK"
    if status_raw == "disabled":
        return "DISABLED"
    if status_raw == "fetch_error":
        return "FETCH_ERR"
    if status_raw == "alert_error":
        return "ALERT_ERR"
    return status_raw.upper()[:12] if status_raw else "-"


def render_cycle_rich(cycle: dict[str, Any], *, title: str = "") -> Any:
    """Return a Rich Table for a cycle.

    The return type is intentionally 'object' to avoid importing rich at module
    import time (the monitor can still run without the UI deps).
    """
    from rich.table import Table
    from rich.text import Text

    ran_at = str(cycle.get("ran_at", ""))
    total_matches = int(cycle.get("total_matches", 0) or 0)
    total_new = int(cycle.get("total_new", 0) or 0)

    table_title = title or f"Last run: {_format_checked_at(ran_at)} | matches={total_matches} new={total_new}"
    table = Table(title=table_title, show_header=True, header_style="bold cyan")
    table.add_column("Watcher", style="bold", no_wrap=True)
    table.add_column("Status", no_wrap=True)
    table.add_column("Match", justify="right", no_wrap=True)
    table.add_column("New", justify="right", no_wrap=True)
    table.add_column("Alert", justify="right", no_wrap=True)
    table.add_column("Store", no_wrap=True)
    table.add_column("Category", no_wrap=True)
    table.add_column("Checked", no_wrap=True)
    table.add_column("Error", overflow="fold")

    for item in _cycle_to_rows(cycle):
        watcher_id = str(item.get("watcher_id", ""))
        status_raw = str(item.get("status", ""))
        status = _status_label(status_raw)

        if status == "OK":
            status_text = Text(status, style="green")
        elif status == "DISABLED":
            status_text = Text(status, style="dim")
        else:
            status_text = Text(status, style="red")

        matched = str(int(item.get("matched_count", 0) or 0))
        new_count = str(int(item.get("new_count", 0) or 0))
        alerts = str(int(item.get("alerts_sent", 0) or 0))
        store = str(item.get("store", ""))
        category = str(item.get("category", ""))
        checked = _format_checked_at(str(item.get("checked_at", "")))
        error_msg = str(item.get("error", "")).strip()

        table.add_row(
            watcher_id,
            status_text,
            matched,
            new_count,
            alerts,
            store,
            category,
            checked,
            error_msg,
        )

    return table


def _split_csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def _join_csv(values: list[str] | set[str]) -> str:
    if isinstance(values, set):
        return ", ".join(sorted(values))
    return ", ".join(values)


def _fmt_num(value: float | None) -> str:
    if value is None:
        return ""
    if float(value).is_integer():
        return str(int(value))
    return str(value)


def resolve_state_path(config: AppConfig, config_path: Path) -> Path:
    state_path = Path(config.state_file)
    if not state_path.is_absolute():
        state_path = (config_path.parent / state_path).resolve()
    return state_path


def _toml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def _toml_str_list(values: list[str]) -> str:
    return "[" + ", ".join(_toml_quote(v) for v in values) + "]"


def _toml_num(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return str(value)


def serialize_config_toml(config: AppConfig) -> str:
    lines: list[str] = []
    lines.append(f"poll_interval_seconds = {int(config.poll_interval_seconds)}")
    lines.append(f"state_file = {_toml_quote(config.state_file)}")
    lines.append("")

    if config.pushover is not None:
        lines.append("[pushover]")
        lines.append(f"token = {_toml_quote(config.pushover.token)}")
        lines.append(f"user = {_toml_quote(config.pushover.user)}")
        lines.append(f"device = {_toml_quote(config.pushover.device)}")
        lines.append(f"priority = {int(config.pushover.priority)}")
        lines.append(f"sound = {_toml_quote(config.pushover.sound)}")
        lines.append("")

    for watcher in config.watchers:
        lines.append("[[watchers]]")
        lines.append(f"id = {_toml_quote(watcher.watcher_id)}")
        lines.append(f"enabled = {'true' if watcher.enabled else 'false'}")
        lines.append(f"store = {_toml_quote(watcher.store)}")
        lines.append(f"category = {_toml_quote(watcher.category)}")
        lines.append(
            f"name_contains_all = {_toml_str_list(list(watcher.name_contains_all))}"
        )
        lines.append(
            f"name_contains_any = {_toml_str_list(list(watcher.name_contains_any))}"
        )
        lines.append(
            f"exclude_contains = {_toml_str_list(list(watcher.exclude_contains))}"
        )
        lines.append(f"name_regex = {_toml_quote(watcher.name_regex)}")
        if watcher.min_price is not None:
            lines.append(f"min_price = {_toml_num(watcher.min_price)}")
        if watcher.max_price is not None:
            lines.append(f"max_price = {_toml_num(watcher.max_price)}")
        lines.append(f"min_saving = {_toml_num(watcher.min_saving)}")
        lines.append(
            f"min_saving_percentage = {_toml_num(watcher.min_saving_percentage)}"
        )
        if watcher.max_previous_price is not None:
            lines.append(f"max_previous_price = {_toml_num(watcher.max_previous_price)}")
        lines.append(f"model_in = {_toml_str_list(sorted(watcher.model_in))}")
        lines.append(f"alert_title = {_toml_quote(watcher.alert_title)}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def save_config_toml(config_path: Path, config: AppConfig) -> None:
    content = serialize_config_toml(config)
    config_path.parent.mkdir(parents=True, exist_ok=True)

    if config_path.exists():
        backup_path = Path(str(config_path) + ".bak")
        shutil.copy2(config_path, backup_path)

    with config_path.open("w", encoding="utf-8") as f:
        f.write(content)


def cmd_interactive(
    config: AppConfig,
    config_path: Path,
    state_path: Path,
    default_interval: int,
    default_dry_run: bool,
) -> int:
    if not sys.stdout.isatty() or not sys.stdin.isatty():
        print(
            "Interactive mode requires a TTY. Try: monitor.py check or monitor.py run",
            file=sys.stderr,
        )
        return 1

    import questionary
    from questionary import Choice
    from rich.console import Console
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text

    console = Console()
    qstyle = questionary.Style(
        [
            ("qmark", "fg:#00afff bold"),
            ("question", "bold"),
            ("pointer", "fg:#00afff bold"),
            ("highlighted", "fg:#00afff bold"),
        ]
    )

    categories = sorted(set(CATEGORY_ALIASES.values()))

    def pause() -> None:
        questionary.press_any_key_to_continue(style=qstyle).ask()

    def show_header() -> None:
        console.print(
            Panel(
                Text("Apple Refurb Monitor", style="bold cyan"),
                subtitle=(
                    f"config={config_path.name}  state={state_path.name}  "
                    "(all editable from this UI)"
                ),
            )
        )

    def ask_text(prompt: str, default: str = "") -> str | None:
        return questionary.text(prompt, default=default, style=qstyle).ask()

    def ask_confirm(prompt: str, default: bool = False) -> bool | None:
        return questionary.confirm(prompt, default=default, style=qstyle).ask()

    def ask_optional_float(
        prompt: str,
        default_value: float | None,
    ) -> tuple[bool, float | None]:
        raw = ask_text(prompt, _fmt_num(default_value))
        if raw is None:
            return (False, None)
        value = raw.strip()
        if not value:
            return (True, None)
        try:
            return (True, float(value))
        except ValueError:
            console.print("[red]Expected a number or blank.[/red]")
            return (False, None)

    def ask_float(prompt: str, default_value: float) -> tuple[bool, float]:
        raw = ask_text(prompt, _fmt_num(default_value))
        if raw is None:
            return (False, default_value)
        value = raw.strip()
        if not value:
            return (True, default_value)
        try:
            return (True, float(value))
        except ValueError:
            console.print("[red]Expected a number.[/red]")
            return (False, default_value)

    def persist_config() -> bool:
        nonlocal state_path, default_interval
        try:
            save_config_toml(config_path, config)
            loaded = load_config(config_path)
        except Exception as exc:
            console.print(f"[red]Failed to save config:[/red] {exc}")
            return False

        config.poll_interval_seconds = loaded.poll_interval_seconds
        config.state_file = loaded.state_file
        config.pushover = loaded.pushover
        config.watchers = loaded.watchers
        state_path = resolve_state_path(config, config_path)
        default_interval = config.poll_interval_seconds
        console.print(f"[green]Saved config.[/green] Backup: {config_path}.bak")
        return True

    def format_watcher_filters(watcher: WatcherConfig) -> str:
        filters: list[str] = []
        if watcher.name_contains_all:
            filters.append(f"all={watcher.name_contains_all}")
        if watcher.name_contains_any:
            filters.append(f"any={watcher.name_contains_any}")
        if watcher.exclude_contains:
            filters.append(f"exclude={watcher.exclude_contains}")
        if watcher.name_regex:
            filters.append(f"regex={watcher.name_regex}")
        if watcher.model_in:
            filters.append(f"models={sorted(watcher.model_in)}")
        if watcher.min_price is not None:
            filters.append(f"min_price={watcher.min_price}")
        if watcher.max_price is not None:
            filters.append(f"max_price={watcher.max_price}")
        if watcher.min_saving:
            filters.append(f"min_saving={watcher.min_saving}")
        if watcher.min_saving_percentage:
            filters.append(f"min_saving_pct={watcher.min_saving_percentage}")
        return "; ".join(filters) if filters else "(none)"

    def show_watchers_table() -> None:
        table = Table(
            title="Configured watchers",
            show_header=True,
            header_style="bold cyan",
        )
        table.add_column("ID", style="bold")
        table.add_column("Enabled", no_wrap=True)
        table.add_column("Store", no_wrap=True)
        table.add_column("Category", no_wrap=True)
        table.add_column("Filters", overflow="fold")

        for watcher in config.watchers:
            table.add_row(
                watcher.watcher_id,
                "yes" if watcher.enabled else "no",
                watcher.store,
                watcher.category,
                format_watcher_filters(watcher),
            )

        console.print(table)

    def choose_watcher(prompt: str) -> int | None:
        if not config.watchers:
            console.print("[yellow]No watchers configured yet.[/yellow]")
            return None

        choices = [
            Choice(
                f"{w.watcher_id} ({'on' if w.enabled else 'off'}, {w.store}/{w.category})",
                value=i,
            )
            for i, w in enumerate(config.watchers)
        ]
        choices.append(Choice("Cancel", value=-1))
        pick = questionary.select(prompt, choices=choices, style=qstyle).ask()
        if pick is None or int(pick) < 0:
            return None
        return int(pick)

    def prompt_watcher(existing: WatcherConfig | None = None) -> WatcherConfig | None:
        existing_id = existing.watcher_id if existing else ""

        while True:
            watcher_id = ask_text("Watcher ID:", existing_id or "")
            if watcher_id is None:
                return None
            watcher_id = watcher_id.strip()
            if not watcher_id:
                console.print("[red]Watcher ID is required.[/red]")
                continue
            if any(
                w.watcher_id == watcher_id and w.watcher_id != existing_id
                for w in config.watchers
            ):
                console.print("[red]Watcher ID already exists.[/red]")
                continue
            break

        enabled = ask_confirm("Enabled?", existing.enabled if existing else True)
        if enabled is None:
            return None

        store = ask_text("Store country code:", existing.store if existing else "us")
        if store is None:
            return None
        store = store.strip().lower()
        if not store:
            console.print("[red]Store is required.[/red]")
            return None

        category_default = existing.category if existing else "macs"
        category = questionary.select(
            "Category:",
            choices=[Choice(c, value=c) for c in categories],
            default=category_default,
            style=qstyle,
        ).ask()
        if category is None:
            return None

        all_csv = ask_text(
            "Name contains all (comma-separated):",
            _join_csv(existing.name_contains_all if existing else []),
        )
        if all_csv is None:
            return None

        any_csv = ask_text(
            "Name contains any (comma-separated):",
            _join_csv(existing.name_contains_any if existing else []),
        )
        if any_csv is None:
            return None

        exclude_csv = ask_text(
            "Exclude contains (comma-separated):",
            _join_csv(existing.exclude_contains if existing else []),
        )
        if exclude_csv is None:
            return None

        regex = ask_text("Name regex (optional):", existing.name_regex if existing else "")
        if regex is None:
            return None

        model_csv = ask_text(
            "Model whitelist (comma-separated, optional):",
            _join_csv(existing.model_in if existing else set()),
        )
        if model_csv is None:
            return None

        ok, min_price = ask_optional_float(
            "Min price (blank = none):",
            existing.min_price if existing else None,
        )
        if not ok:
            return None

        ok, max_price = ask_optional_float(
            "Max price (blank = none):",
            existing.max_price if existing else None,
        )
        if not ok:
            return None

        ok, min_saving = ask_float(
            "Min saving amount:",
            existing.min_saving if existing else 0.0,
        )
        if not ok:
            return None

        ok, min_saving_pct = ask_float(
            "Min saving percentage (0-100):",
            existing.min_saving_percentage if existing else 0.0,
        )
        if not ok:
            return None

        ok, max_previous_price = ask_optional_float(
            "Max previous price (blank = none):",
            existing.max_previous_price if existing else None,
        )
        if not ok:
            return None

        alert_title = ask_text("Alert title (optional):", existing.alert_title if existing else "")
        if alert_title is None:
            return None

        try:
            return WatcherConfig(
                watcher_id=watcher_id,
                enabled=bool(enabled),
                store=store,
                category=normalize_category(str(category)),
                name_contains_all=_split_csv(all_csv),
                name_contains_any=_split_csv(any_csv),
                exclude_contains=_split_csv(exclude_csv),
                name_regex=regex.strip(),
                min_price=min_price,
                max_price=max_price,
                min_saving=float(min_saving),
                min_saving_percentage=float(min_saving_pct),
                max_previous_price=max_previous_price,
                model_in={m.strip().upper() for m in _split_csv(model_csv)},
                alert_title=alert_title.strip(),
            )
        except ValueError as exc:
            console.print(f"[red]Invalid watcher config:[/red] {exc}")
            return None

    def manage_watchers() -> None:
        while True:
            console.clear()
            show_header()
            show_watchers_table()

            action = questionary.select(
                "Watcher actions:",
                choices=[
                    Choice("Add watcher", value="add"),
                    Choice("Edit watcher", value="edit"),
                    Choice("Toggle enabled", value="toggle"),
                    Choice("Delete watcher", value="delete"),
                    Choice("Back", value="back"),
                ],
                style=qstyle,
            ).ask()

            if action in {None, "back"}:
                return

            if action == "add":
                watcher = prompt_watcher(None)
                if watcher is None:
                    pause()
                    continue
                config.watchers.append(watcher)
                if persist_config():
                    console.print(f"[green]Added watcher:[/green] {watcher.watcher_id}")
                pause()
                continue

            if action == "edit":
                idx = choose_watcher("Select watcher to edit:")
                if idx is None:
                    continue
                updated = prompt_watcher(config.watchers[idx])
                if updated is None:
                    pause()
                    continue
                config.watchers[idx] = updated
                if persist_config():
                    console.print(f"[green]Updated watcher:[/green] {updated.watcher_id}")
                pause()
                continue

            if action == "toggle":
                idx = choose_watcher("Select watcher to toggle:")
                if idx is None:
                    continue
                watcher = config.watchers[idx]
                watcher.enabled = not watcher.enabled
                if persist_config():
                    state = "enabled" if watcher.enabled else "disabled"
                    console.print(f"[green]Watcher {watcher.watcher_id} is now {state}.[/green]")
                pause()
                continue

            if action == "delete":
                if len(config.watchers) <= 1:
                    console.print("[yellow]At least one watcher is required.[/yellow]")
                    pause()
                    continue
                idx = choose_watcher("Select watcher to delete:")
                if idx is None:
                    continue
                watcher = config.watchers[idx]
                really = ask_confirm(
                    f"Delete watcher '{watcher.watcher_id}'?",
                    default=False,
                )
                if not really:
                    continue
                config.watchers.pop(idx)
                if persist_config():
                    console.print(f"[green]Deleted watcher:[/green] {watcher.watcher_id}")
                pause()
                continue

    def manage_settings() -> None:
        while True:
            console.clear()
            show_header()
            console.print(f"poll_interval_seconds = [bold]{config.poll_interval_seconds}[/bold]")
            console.print(f"state_file = [bold]{config.state_file}[/bold]")
            if config.pushover is None:
                console.print("pushover = [bold]disabled[/bold]")
            else:
                console.print(
                    "pushover = [bold]enabled[/bold] "
                    f"(user={config.pushover.user}, device={config.pushover.device or '-'})"
                )

            action = questionary.select(
                "Settings actions:",
                choices=[
                    Choice("Set poll interval", value="interval"),
                    Choice("Set state file path", value="state_file"),
                    Choice("Configure Pushover", value="pushover"),
                    Choice("Disable Pushover", value="disable_pushover"),
                    Choice("Back", value="back"),
                ],
                style=qstyle,
            ).ask()

            if action in {None, "back"}:
                return

            if action == "interval":
                raw = ask_text("Poll interval seconds:", str(config.poll_interval_seconds))
                if raw is None:
                    continue
                try:
                    value = int(raw.strip())
                    if value <= 0:
                        raise ValueError("must be positive")
                except ValueError:
                    console.print("[red]Interval must be a positive integer.[/red]")
                    pause()
                    continue
                config.poll_interval_seconds = value
                persist_config()
                pause()
                continue

            if action == "state_file":
                raw = ask_text("State file path:", config.state_file)
                if raw is None:
                    continue
                value = raw.strip()
                if not value:
                    console.print("[red]State file path cannot be empty.[/red]")
                    pause()
                    continue
                config.state_file = value
                persist_config()
                pause()
                continue

            if action == "pushover":
                current = config.pushover
                token = ask_text("Pushover app token:", current.token if current else "")
                if token is None:
                    continue
                user = ask_text("Pushover user key:", current.user if current else "")
                if user is None:
                    continue
                device = ask_text("Pushover device (optional):", current.device if current else "")
                if device is None:
                    continue
                priority_raw = ask_text(
                    "Pushover priority:",
                    str(current.priority if current else 0),
                )
                if priority_raw is None:
                    continue
                sound = ask_text("Pushover sound (optional):", current.sound if current else "")
                if sound is None:
                    continue

                try:
                    priority = int(priority_raw.strip())
                except ValueError:
                    console.print("[red]Priority must be an integer.[/red]")
                    pause()
                    continue

                if not token.strip() or not user.strip():
                    console.print("[red]Token and user are required to enable Pushover.[/red]")
                    pause()
                    continue

                config.pushover = PushoverConfig(
                    token=token.strip(),
                    user=user.strip(),
                    device=device.strip(),
                    priority=priority,
                    sound=sound.strip(),
                )
                persist_config()
                pause()
                continue

            if action == "disable_pushover":
                confirm = ask_confirm("Disable Pushover alerts?", default=False)
                if confirm:
                    config.pushover = None
                    persist_config()
                pause()
                continue

    def run_and_show_cycle(*, dry_run: bool) -> None:
        if not dry_run and config.pushover is None:
            console.print(
                "[yellow]Pushover is not configured; running in dry-run.[/yellow]"
            )
            dry_run = True
        cycle = run_cycle(config, state_path=state_path, dry_run=dry_run, verbose=False)
        console.print(render_cycle_rich(cycle))

    def show_state_summary() -> None:
        state = load_state(state_path)
        watchers = state.get("watchers", {})
        if not isinstance(watchers, dict) or not watchers:
            console.print("[dim]No state yet (run a check first).[/dim]")
            return

        table = Table(
            title="State (last run per watcher)",
            show_header=True,
            header_style="bold cyan",
        )
        table.add_column("Watcher", style="bold")
        table.add_column("Last Checked", no_wrap=True)
        table.add_column("Matches", justify="right", no_wrap=True)
        table.add_column("New", justify="right", no_wrap=True)
        table.add_column("Last Error", overflow="fold")

        for watcher_id, entry in sorted(watchers.items()):
            if not isinstance(entry, dict):
                continue
            table.add_row(
                str(watcher_id),
                _format_checked_at(str(entry.get("last_checked", ""))),
                str(int(entry.get("last_match_count", 0) or 0)),
                str(int(entry.get("last_new_count", 0) or 0)),
                str(entry.get("last_error", "") or ""),
            )

        console.print(table)

    def watch_dashboard(interval_seconds: int, *, dry_run: bool) -> None:
        if interval_seconds <= 0:
            interval_seconds = default_interval

        if not dry_run and config.pushover is None:
            console.print(
                "[yellow]Pushover is not configured; watch mode will run in dry-run.[/yellow]"
            )
            dry_run = True

        console.print(
            f"[dim]Watch mode running every {interval_seconds}s. Press Ctrl+C to stop.[/dim]"
        )

        cycle: dict[str, Any] = {
            "ran_at": now_iso(),
            "total_matches": 0,
            "total_new": 0,
            "watchers": [],
        }
        last_error = ""

        def render_panel(next_in: int) -> Any:
            from rich.console import Group

            top = Text(
                f"interval={interval_seconds}s  next={max(0, next_in)}s  mode={'DRY' if dry_run else 'LIVE'}",
                style="dim",
            )
            err = (
                Text(f"error: {last_error}", style="red")
                if last_error
                else Text("", style="dim")
            )
            return Panel(
                Group(top, err, render_cycle_rich(cycle)),
                title="Apple Refurb Monitor",
                subtitle=str(config_path),
            )

        try:
            with Live(render_panel(interval_seconds), refresh_per_second=4, console=console) as live:
                while True:
                    started = time.monotonic()
                    try:
                        cycle = run_cycle(
                            config,
                            state_path=state_path,
                            dry_run=dry_run,
                            verbose=False,
                        )
                        last_error = ""
                    except Exception as exc:
                        last_error = str(exc)
                        cycle = {
                            "ran_at": now_iso(),
                            "total_matches": 0,
                            "total_new": 0,
                            "watchers": [],
                        }

                    elapsed = time.monotonic() - started
                    remaining = max(1, interval_seconds - int(elapsed))
                    for seconds_left in range(remaining, 0, -1):
                        live.update(render_panel(seconds_left))
                        time.sleep(1)
        except KeyboardInterrupt:
            console.print("\n[dim]Stopped watch mode.[/dim]")

    while True:
        console.clear()
        show_header()

        choice = questionary.select(
            "Choose an action:",
            choices=[
                Choice("Run one check now", value="check"),
                Choice("Watch dashboard (continuous)", value="watch"),
                Choice("Manage watchers", value="manage_watchers"),
                Choice("Manage settings", value="manage_settings"),
                Choice("Show state summary", value="state"),
                Choice("Test Pushover", value="test_pushover"),
                Choice("Reset dedupe state", value="reset_seen"),
                Choice("Quit", value="quit"),
            ],
            style=qstyle,
        ).ask()

        if choice in {None, "quit"}:
            console.print("\n[dim]Bye.[/dim]")
            return 0

        if choice == "check":
            dry = default_dry_run
            if config.pushover is not None:
                dry = not questionary.confirm(
                    "Send alerts if matches are found?",
                    default=not default_dry_run,
                    style=qstyle,
                ).ask()
            console.clear()
            show_header()
            run_and_show_cycle(dry_run=dry)
            pause()
            continue

        if choice == "watch":
            interval_text = questionary.text(
                "Interval seconds:",
                default=str(default_interval),
                style=qstyle,
            ).ask()
            try:
                interval_seconds = int(str(interval_text).strip()) if interval_text else default_interval
            except ValueError:
                interval_seconds = default_interval

            dry = default_dry_run
            if config.pushover is not None:
                dry = not questionary.confirm(
                    "Send alerts while watching?",
                    default=not default_dry_run,
                    style=qstyle,
                ).ask()
            console.clear()
            show_header()
            watch_dashboard(interval_seconds, dry_run=dry)
            pause()
            continue

        if choice == "manage_watchers":
            manage_watchers()
            continue

        if choice == "manage_settings":
            manage_settings()
            continue

        if choice == "state":
            console.clear()
            show_header()
            show_state_summary()
            pause()
            continue

        if choice == "test_pushover":
            console.clear()
            show_header()
            if config.pushover is None:
                console.print("[yellow]Pushover is disabled. Enable it in Manage settings.[/yellow]")
            else:
                msg = questionary.text(
                    "Test message:",
                    default="Apple refurb monitor test notification",
                    style=qstyle,
                ).ask()
                try:
                    request_id = send_pushover(
                        config.pushover,
                        title="Apple Refurb Monitor Test",
                        message=str(msg or "test"),
                    )
                    console.print(f"[green]Sent[/green] (request {request_id})")
                except Exception as exc:
                    console.print(f"[red]Failed:[/red] {exc}")
            pause()
            continue

        if choice == "reset_seen":
            console.clear()
            show_header()
            scope = questionary.select(
                "Clear dedupe state for:",
                choices=[
                    Choice("All watchers", value="all"),
                    Choice("One watcher", value="one"),
                    Choice("Cancel", value="cancel"),
                ],
                style=qstyle,
            ).ask()

            if scope in {None, "cancel"}:
                continue

            if scope == "all":
                if questionary.confirm(
                    "Really clear all seen URLs?",
                    default=False,
                    style=qstyle,
                ).ask():
                    cmd_reset_seen(state_path, "")
                pause()
                continue

            watcher_ids = [w.watcher_id for w in config.watchers]
            pick = questionary.select(
                "Select watcher:",
                choices=[Choice(wid, value=wid) for wid in watcher_ids] + [Choice("Cancel", value="")],
                style=qstyle,
            ).ask()
            if pick:
                cmd_reset_seen(state_path, str(pick))
            pause()
            continue

    return 0


def render_tui_frame(
    config_path: Path,
    state_path: Path,
    interval: int,
    dry_run: bool,
    cycle: dict[str, Any],
    next_run_in: int,
    cycle_error: str = "",
) -> None:
    terminal_width = shutil.get_terminal_size(fallback=(120, 40)).columns

    ran_at = str(cycle.get("ran_at", ""))
    total_matches = int(cycle.get("total_matches", 0) or 0)
    total_new = int(cycle.get("total_new", 0) or 0)
    watchers = cycle.get("watchers", [])
    if not isinstance(watchers, list):
        watchers = []

    mode = "DRY RUN" if dry_run else "LIVE"
    header = (
        f"Apple Refurb Monitor TUI  [{mode}]  interval={interval}s  "
        f"next={max(0, next_run_in)}s"
    )
    line = "=" * max(20, min(terminal_width, 120))

    rows: list[str] = []
    rows.append(header)
    rows.append(line)
    rows.append(f"Config: {config_path}")
    rows.append(f"State:  {state_path}")
    rows.append(f"Last run: {ran_at} | Total matches: {total_matches} | New: {total_new}")
    if cycle_error:
        rows.append(f"Cycle error: {cycle_error}")
    rows.append("")

    table_header = (
        f"{'Watcher':24} {'Status':10} {'Match':>5} {'New':>4} "
        f"{'Alert':>5} {'Store':>5} {'Category':>10} {'Checked At':19}"
    )
    rows.append(table_header)
    rows.append("-" * min(len(table_header), max(20, terminal_width)))

    for item in watchers:
        if not isinstance(item, dict):
            continue

        watcher_id = _trim(str(item.get("watcher_id", "")), 24)
        status_raw = str(item.get("status", ""))
        if status_raw == "ok":
            status = "OK"
        elif status_raw == "disabled":
            status = "DISABLED"
        elif status_raw == "fetch_error":
            status = "FETCH_ERR"
        elif status_raw == "alert_error":
            status = "ALERT_ERR"
        else:
            status = _trim(status_raw.upper(), 10)

        matched = int(item.get("matched_count", 0) or 0)
        new_count = int(item.get("new_count", 0) or 0)
        alerts = int(item.get("alerts_sent", 0) or 0)
        store = _trim(str(item.get("store", "")), 5)
        category = _trim(str(item.get("category", "")), 10)
        checked_raw = str(item.get("checked_at", ""))
        checked = checked_raw.replace("T", " ")[:19]

        row = (
            f"{watcher_id:24} {status:10} {matched:>5} {new_count:>4} "
            f"{alerts:>5} {store:>5} {category:>10} {checked:19}"
        )
        rows.append(_trim(row, terminal_width))

        error_msg = str(item.get("error", "")).strip()
        if error_msg:
            rows.append(_trim(f"  error: {error_msg}", terminal_width))

    rows.append("")
    rows.append("Ctrl+C to exit")
    output = "\n".join(rows)

    if sys.stdout.isatty():
        sys.stdout.write("\033[2J\033[H")
    sys.stdout.write(output + "\n")
    sys.stdout.flush()


def cmd_tui(
    config: AppConfig,
    config_path: Path,
    state_path: Path,
    interval: int,
    dry_run: bool,
) -> int:
    if interval <= 0:
        print("Polling interval must be positive", file=sys.stderr)
        return 1

    cycle: dict[str, Any] = {
        "ran_at": now_iso(),
        "total_matches": 0,
        "total_new": 0,
        "watchers": [],
    }
    cycle_error = ""

    if sys.stdout.isatty():
        sys.stdout.write("\033[?25l")
        sys.stdout.flush()

    try:
        while True:
            started = time.monotonic()
            try:
                cycle = run_cycle(
                    config,
                    state_path=state_path,
                    dry_run=dry_run,
                    verbose=False,
                )
                cycle_error = ""
            except Exception as exc:
                cycle = {
                    "ran_at": now_iso(),
                    "total_matches": 0,
                    "total_new": 0,
                    "watchers": [],
                }
                cycle_error = str(exc)

            elapsed = time.monotonic() - started
            remaining = max(1, interval - int(elapsed))

            for seconds_left in range(remaining, 0, -1):
                render_tui_frame(
                    config_path=config_path,
                    state_path=state_path,
                    interval=interval,
                    dry_run=dry_run,
                    cycle=cycle,
                    next_run_in=seconds_left,
                    cycle_error=cycle_error,
                )
                time.sleep(1)
    except KeyboardInterrupt:
        if sys.stdout.isatty():
            sys.stdout.write("\033[2J\033[H")
            sys.stdout.flush()
        print("TUI stopped by user")
        return 0
    finally:
        if sys.stdout.isatty():
            sys.stdout.write("\033[?25h")
            sys.stdout.flush()


def cmd_list_watchers(config: AppConfig) -> int:
    print("Configured watchers:")
    for watcher in config.watchers:
        filters: list[str] = []
        if watcher.name_contains_all:
            filters.append(f"all={watcher.name_contains_all}")
        if watcher.name_contains_any:
            filters.append(f"any={watcher.name_contains_any}")
        if watcher.exclude_contains:
            filters.append(f"exclude={watcher.exclude_contains}")
        if watcher.name_regex:
            filters.append(f"regex={watcher.name_regex}")
        if watcher.model_in:
            filters.append(f"models={sorted(watcher.model_in)}")
        if watcher.min_price is not None:
            filters.append(f"min_price={watcher.min_price}")
        if watcher.max_price is not None:
            filters.append(f"max_price={watcher.max_price}")
        if watcher.min_saving:
            filters.append(f"min_saving={watcher.min_saving}")
        if watcher.min_saving_percentage:
            filters.append(f"min_saving_pct={watcher.min_saving_percentage}")

        status = "enabled" if watcher.enabled else "disabled"
        filter_text = "; ".join(filters) if filters else "(no filters)"
        print(
            f"- {watcher.watcher_id}: {status}, "
            f"store={watcher.store}, category={watcher.category}, {filter_text}"
        )
    return 0


def cmd_test_pushover(config: AppConfig, message: str) -> int:
    if config.pushover is None:
        print("Error: [pushover] config is required", file=sys.stderr)
        return 1

    title = "Apple Refurb Monitor Test"
    try:
        request_id = send_pushover(config.pushover, title=title, message=message)
    except Exception as exc:
        print(f"Test notification failed: {exc}", file=sys.stderr)
        return 1

    print(f"Test notification sent successfully (request {request_id})")
    return 0


def cmd_reset_seen(state_path: Path, watcher_id: str) -> int:
    state = load_state(state_path)
    watchers = state.setdefault("watchers", {})

    if watcher_id:
        if watcher_id not in watchers:
            print(f"Watcher '{watcher_id}' not present in state")
            return 0
        entry = watchers.get(watcher_id)
        if not isinstance(entry, dict):
            watchers[watcher_id] = {}
            entry = watchers[watcher_id]
        entry["seen_urls"] = []
        save_state(state_path, state)
        print(f"Cleared seen URL state for watcher '{watcher_id}'")
        return 0

    for value in watchers.values():
        if isinstance(value, dict):
            value["seen_urls"] = []

    save_state(state_path, state)
    print("Cleared seen URL state for all watchers")
    return 0


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()

    try:
        config = load_config(config_path)
    except Exception as exc:
        print(f"Failed to load config: {exc}", file=sys.stderr)
        return 1

    state_path = Path(config.state_file)
    if not state_path.is_absolute():
        state_path = (config_path.parent / state_path).resolve()

    command = args.command

    if command in {"check", "run", "tui"} and not bool(getattr(args, "dry_run", False)):
        if config.pushover is None:
            print(
                "Error: [pushover] config is required for non-dry-run checks",
                file=sys.stderr,
            )
            return 1

    if command == "list-watchers":
        return cmd_list_watchers(config)

    if command == "test-pushover":
        return cmd_test_pushover(config, args.message)

    if command == "reset-seen":
        return cmd_reset_seen(state_path, args.watcher_id)

    if command == "check":
        try:
            run_cycle(
                config,
                state_path=state_path,
                dry_run=bool(args.dry_run),
                verbose=True,
            )
        except Exception as exc:
            print(f"Check failed: {exc}", file=sys.stderr)
            return 1
        return 0

    if command == "run":
        interval = (
            args.interval
            if args.interval is not None
            else config.poll_interval_seconds
        )
        if interval <= 0:
            print("Polling interval must be positive", file=sys.stderr)
            return 1

        log(
            f"Starting monitor with {interval}s interval. "
            f"Config: {config_path}"
        )
        log(f"State file: {state_path}")

        try:
            while True:
                try:
                    run_cycle(
                        config,
                        state_path=state_path,
                        dry_run=bool(args.dry_run),
                        verbose=True,
                    )
                except Exception as exc:
                    log(f"Cycle failed: {exc}")
                time.sleep(interval)
        except KeyboardInterrupt:
            log("Stopped by user")
            return 0

    if command == "interactive":
        interval = (
            args.interval
            if args.interval is not None
            else config.poll_interval_seconds
        )
        return cmd_interactive(
            config,
            config_path=config_path,
            state_path=state_path,
            default_interval=interval,
            default_dry_run=bool(args.dry_run),
        )

    if command == "tui":
        interval = (
            args.interval
            if args.interval is not None
            else config.poll_interval_seconds
        )
        return cmd_tui(
            config,
            config_path=config_path,
            state_path=state_path,
            interval=interval,
            dry_run=bool(args.dry_run),
        )

    print(f"Unknown command: {command}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
