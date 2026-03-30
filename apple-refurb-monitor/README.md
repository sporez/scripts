# Apple Refurb Monitor

Simple Python monitor for the Apple refurbished store with Pushover alerts.

It supports:

- Multiple watchers in one config file
- Configurable polling interval
- Flexible matching rules (keywords, regex, model IDs, price/savings)
- Deduping so you only get alerted once per product URL
- Full interactive management from TUI (add/edit/delete/toggle watchers, settings, and Pushover)

## Requirements

- Python 3.11+
- Dependencies from `requirements.txt`

## Install

```bash
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
```

## Quick Start

1. Copy the example config:

```bash
cp watchers.example.toml watchers.toml
```

2. Edit `watchers.toml`:

- Set `[pushover].token` and `[pushover].user`
- Add/remove `[[watchers]]` blocks for the configs you want

3. Run one cycle to verify matching:

```bash
./.venv/bin/python monitor.py check --config watchers.toml --dry-run
```

4. Send a test push notification:

```bash
./.venv/bin/python monitor.py test-pushover --config watchers.toml
```

5. Run continuously:

```bash
./.venv/bin/python monitor.py run --config watchers.toml
```

Or run the interactive UI (mLog-style menu):

```bash
./.venv/bin/python monitor.py interactive --config watchers.toml
```

In interactive mode you can manage everything without manual file editing:

- Add/edit/delete/toggle watchers
- Update poll interval and state file path
- Configure or disable Pushover
- Run one-off checks or start continuous watch mode

Manual editing of `watchers.toml` is still supported, but optional.

## Commands

```bash
./.venv/bin/python monitor.py list-watchers --config watchers.toml
./.venv/bin/python monitor.py check --config watchers.toml
./.venv/bin/python monitor.py run --config watchers.toml
./.venv/bin/python monitor.py interactive --config watchers.toml
./.venv/bin/python monitor.py test-pushover --config watchers.toml
./.venv/bin/python monitor.py reset-seen --config watchers.toml
./.venv/bin/python monitor.py reset-seen --config watchers.toml --watcher-id mba-m4-16gb-under-1300
```

## Watcher fields

Per `[[watchers]]` block:

- `id` (required): unique watcher ID
- `enabled` (bool): enable/disable watcher
- `store`: Apple store country code like `us`, `uk`, `de`, `fr`
- `category`: one of `macs`, `iphones`, `ipads`, `watches`, `airpods`, `appletvs`, `homepods`, `accessories`, `clearance`
- `name_contains_all`: all terms must appear in product name
- `name_contains_any`: at least one term must appear
- `exclude_contains`: if any term appears, product is excluded
- `name_regex`: optional regex against product name
- `model_in`: optional list of Apple model IDs/SKUs to allow
- `min_price` / `max_price`
- `min_saving` (absolute currency amount)
- `min_saving_percentage` (0-100 scale)
- `alert_title`: custom Pushover title

## State file

The monitor stores seen product URLs in `state.json` (or your configured `state_file`) to prevent duplicate alerts.

Use `reset-seen` if you want alerts again for already-seen products.
