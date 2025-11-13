# Scripts Collection

A collection of useful system administration and development scripts.

## Available Scripts

### 1. App Tracker (`app-tracker.py`)

Keep track of all your applications, their URLs, tech stacks, and deployment status.

**Features:**
- Track multiple apps with unique IDs
- Store URLs for different environments (dev, staging, production)
- Record tech stack, repository links, and notes
- Filter apps by status
- Export to markdown format
- Clean, colorful CLI interface

**Quick Start:**
```bash
# Add a new app
./app-tracker.py add

# List all apps
./app-tracker.py list

# List only production apps
./app-tracker.py list production

# View detailed info
./app-tracker.py view <app-id>

# Edit an app
./app-tracker.py edit <app-id>

# Export to markdown
./app-tracker.py export
```

**Data Storage:**
All app data is stored in `apps.json` in the same directory.

### 2. Systemd Service Creator (`create-systemd-service.sh`)

Interactive script to create systemd service files for your scripts and programs.

**Features:**
- Guided interactive setup
- Support for Python scripts and other executables
- Configure restart policies, environment variables, and logging
- Auto-install and enable services (when run with sudo)
- Includes security best practices

**Quick Start:**
```bash
# Run interactively
sudo ./create-systemd-service.sh
```

## Requirements

- **App Tracker**: Python 3.6+
- **Systemd Service Creator**: Bash, systemd

## Installation

1. Clone this repository or download the scripts
2. Make scripts executable:
   ```bash
   chmod +x app-tracker.py create-systemd-service.sh
   ```
3. Optionally, add to your PATH or create aliases

## License

These scripts are provided as-is for personal and commercial use.
