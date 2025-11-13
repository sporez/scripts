# Scripts Collection

A collection of useful system administration and development scripts.

## Available Scripts

### 1. App Dashboard (`app-dashboard.html`)

A beautiful web-based dashboard to track and access all your applications. Perfect for bookmarking your web apps!

**Features:**
- 🎨 Beautiful, responsive UI with gradient backgrounds
- 🔍 Search and filter apps by status
- 🌐 Quick access to all your app URLs (dev, staging, production)
- 💾 Data stored locally in your browser (localStorage)
- 📥 Import/Export functionality for backup and sharing
- ✏️ Easy add, edit, and delete operations
- 📊 Status badges with color coding
- 🚀 One-click access to any environment

**Quick Start:**
```bash
# Simply open the file in your browser
open app-dashboard.html
# or
firefox app-dashboard.html
# or double-click the file
```

**Usage:**
1. Open `app-dashboard.html` in your browser
2. Click "Add New App" to add your first app
3. Fill in the details (name, URLs, tech stack, etc.)
4. Click on any URL to open that app in a new tab
5. Use filters to view apps by status
6. Export your data for backup or import on another machine

**Data Storage:**
All data is stored in your browser's localStorage. Use Export to backup your data!

### 2. App Tracker CLI (`app-tracker.py`)

Command-line version of the app tracker for terminal enthusiasts.

**Quick Start:**
```bash
./app-tracker.py add              # Add a new app
./app-tracker.py list             # List all apps
./app-tracker.py view <app-id>    # View details
./app-tracker.py export           # Export to markdown
```

**Data Storage:**
CLI version uses `apps.json` in the same directory.

### 3. Systemd Service Creator (`create-systemd-service.sh`)

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

- **App Dashboard**: Any modern web browser (Chrome, Firefox, Safari, Edge)
- **App Tracker CLI**: Python 3.6+
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
