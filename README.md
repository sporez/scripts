# Scripts Collection

A collection of useful system administration and development scripts.

## Available Scripts

### 1. Homelab Dashboard (`app-dashboard.html`)

A professional, dark-themed web dashboard for managing and accessing your homelab services. Perfect for sysadmins and homelab enthusiasts!

**Features:**
- Professional dark theme with monospace fonts
- Real-time service statistics (total services, production count)
- Search and filter by environment (dev/staging/prod/archive)
- Quick access to all service URLs across environments
- Data persistence via localStorage with JSON import/export
- First-run wizard with template download
- Status badges with semantic color coding
- Responsive grid layout for any screen size

**Quick Start:**
```bash
# Open the dashboard in your browser
open app-dashboard.html
# or
firefox app-dashboard.html
```

**First-Time Setup:**
1. Open `app-dashboard.html` - you'll see a welcome screen
2. Choose one of three options:
   - **Import existing apps.json** - if you already have a config
   - **Download template** - get a starter `apps.json` to customize
   - **Start fresh** - begin with an empty dashboard

**Daily Usage:**
1. Click "+ Add Service" to register new services
2. Enter URLs for different environments (dev, staging, production)
3. Click any URL to instantly access that service
4. Use filter buttons (ALL/DEV/STAGE/PROD/ARCHIVE) to organize view
5. Export your config regularly as backup

**Data Management:**
- Data stored in browser localStorage (persistent across sessions)
- Export creates timestamped JSON file for backup
- Import replaces current data with JSON file contents
- Template includes example service structure

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
