#!/usr/bin/env python3

"""
App Tracker - Keep track of your applications, URLs, and related information
A simple CLI tool to manage your app inventory
"""

import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

# Configuration
SCRIPT_DIR = Path(__file__).parent
DATA_FILE = SCRIPT_DIR / "apps.json"

# Color codes for terminal output
class Colors:
    GREEN = '\033[0;32m'
    BLUE = '\033[0;34m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    CYAN = '\033[0;36m'
    MAGENTA = '\033[0;35m'
    NC = '\033[0m'  # No Color
    BOLD = '\033[1m'


def print_info(message: str):
    print(f"{Colors.BLUE}ℹ {Colors.NC}{message}")


def print_success(message: str):
    print(f"{Colors.GREEN}✓{Colors.NC} {message}")


def print_warning(message: str):
    print(f"{Colors.YELLOW}⚠{Colors.NC} {message}")


def print_error(message: str):
    print(f"{Colors.RED}✗{Colors.NC} {message}")


def print_header(message: str):
    print()
    print(f"{Colors.GREEN}{'═' * 60}{Colors.NC}")
    print(f"{Colors.GREEN}  {message}{Colors.NC}")
    print(f"{Colors.GREEN}{'═' * 60}{Colors.NC}")
    print()


def load_apps() -> Dict:
    """Load apps from JSON file"""
    if not DATA_FILE.exists():
        return {"apps": []}

    try:
        with open(DATA_FILE, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        print_error(f"Error reading {DATA_FILE}. File may be corrupted.")
        return {"apps": []}


def save_apps(data: Dict):
    """Save apps to JSON file"""
    with open(DATA_FILE, 'w') as f:
        json.dump(data, f, indent=2)


def generate_id(name: str, existing_ids: List[str]) -> str:
    """Generate a unique ID from app name"""
    base_id = name.lower().replace(' ', '-').replace('_', '-')
    # Remove special characters
    base_id = ''.join(c for c in base_id if c.isalnum() or c == '-')

    if base_id not in existing_ids:
        return base_id

    # Add number suffix if ID exists
    counter = 1
    while f"{base_id}-{counter}" in existing_ids:
        counter += 1
    return f"{base_id}-{counter}"


def get_input(prompt: str, default: str = "", required: bool = False) -> str:
    """Get user input with optional default value"""
    if default:
        value = input(f"{prompt} [{default}]: ").strip()
        return value if value else default
    else:
        while True:
            value = input(f"{prompt}: ").strip()
            if value or not required:
                return value
            print_error("This field is required!")


def add_app():
    """Add a new app to the tracker"""
    print_header("Add New App")

    data = load_apps()
    existing_ids = [app['id'] for app in data['apps']]

    # Collect app information
    name = get_input("App name", required=True)
    app_id = generate_id(name, existing_ids)

    description = get_input("Description")

    print("\nURLs (press Enter to skip):")
    url_dev = get_input("  Development URL")
    url_staging = get_input("  Staging URL")
    url_prod = get_input("  Production URL")
    url_other = get_input("  Other URL")

    repo_url = get_input("\nRepository URL (e.g., GitHub)")
    tech_stack = get_input("Technology stack (e.g., Python/Flask, Node.js/React)")

    print("\nStatus:")
    print("  1) Development")
    print("  2) Staging")
    print("  3) Production")
    print("  4) Archived")
    status_choice = get_input("Choose status [1]", "1")
    status_map = {
        "1": "development",
        "2": "staging",
        "3": "production",
        "4": "archived"
    }
    status = status_map.get(status_choice, "development")

    notes = get_input("\nNotes")

    # Build URLs dict (only include non-empty URLs)
    urls = {}
    if url_dev:
        urls['development'] = url_dev
    if url_staging:
        urls['staging'] = url_staging
    if url_prod:
        urls['production'] = url_prod
    if url_other:
        urls['other'] = url_other

    # Create app entry
    now = datetime.now().isoformat()
    app = {
        "id": app_id,
        "name": name,
        "description": description,
        "urls": urls,
        "repository": repo_url,
        "tech_stack": tech_stack,
        "status": status,
        "notes": notes,
        "created_at": now,
        "updated_at": now
    }

    data['apps'].append(app)
    save_apps(data)

    print()
    print_success(f"App '{name}' added successfully!")
    print_info(f"App ID: {app_id}")
    print()


def list_apps(filter_status: Optional[str] = None):
    """List all apps"""
    data = load_apps()
    apps = data['apps']

    if filter_status:
        apps = [app for app in apps if app['status'] == filter_status]
        print_header(f"Apps - Status: {filter_status.title()}")
    else:
        print_header("All Apps")

    if not apps:
        print_info("No apps found.")
        print()
        return

    # Status colors
    status_colors = {
        'development': Colors.YELLOW,
        'staging': Colors.CYAN,
        'production': Colors.GREEN,
        'archived': Colors.RED
    }

    for app in apps:
        status_color = status_colors.get(app['status'], Colors.NC)
        print(f"{Colors.BOLD}{app['name']}{Colors.NC} ({Colors.CYAN}{app['id']}{Colors.NC})")
        print(f"  Status: {status_color}{app['status'].title()}{Colors.NC}")

        if app.get('description'):
            print(f"  Description: {app['description']}")

        if app.get('urls'):
            print("  URLs:")
            for env, url in app['urls'].items():
                print(f"    {env.title()}: {Colors.BLUE}{url}{Colors.NC}")

        if app.get('tech_stack'):
            print(f"  Tech: {app['tech_stack']}")

        print()


def view_app(app_id: str):
    """View detailed information about a specific app"""
    data = load_apps()
    app = next((a for a in data['apps'] if a['id'] == app_id), None)

    if not app:
        print_error(f"App with ID '{app_id}' not found.")
        return

    print_header(f"App Details: {app['name']}")

    print(f"{Colors.BOLD}ID:{Colors.NC} {app['id']}")
    print(f"{Colors.BOLD}Name:{Colors.NC} {app['name']}")
    print(f"{Colors.BOLD}Status:{Colors.NC} {app['status'].title()}")

    if app.get('description'):
        print(f"{Colors.BOLD}Description:{Colors.NC} {app['description']}")

    if app.get('urls'):
        print(f"\n{Colors.BOLD}URLs:{Colors.NC}")
        for env, url in app['urls'].items():
            print(f"  {env.title()}: {Colors.BLUE}{url}{Colors.NC}")

    if app.get('repository'):
        print(f"\n{Colors.BOLD}Repository:{Colors.NC} {Colors.BLUE}{app['repository']}{Colors.NC}")

    if app.get('tech_stack'):
        print(f"{Colors.BOLD}Tech Stack:{Colors.NC} {app['tech_stack']}")

    if app.get('notes'):
        print(f"\n{Colors.BOLD}Notes:{Colors.NC}")
        print(f"  {app['notes']}")

    print(f"\n{Colors.BOLD}Created:{Colors.NC} {app.get('created_at', 'N/A')}")
    print(f"{Colors.BOLD}Updated:{Colors.NC} {app.get('updated_at', 'N/A')}")
    print()


def edit_app(app_id: str):
    """Edit an existing app"""
    data = load_apps()
    app = next((a for a in data['apps'] if a['id'] == app_id), None)

    if not app:
        print_error(f"App with ID '{app_id}' not found.")
        return

    print_header(f"Edit App: {app['name']}")
    print("Press Enter to keep current value, or type new value to update")
    print()

    # Edit fields
    app['name'] = get_input("App name", app['name'])
    app['description'] = get_input("Description", app.get('description', ''))

    print("\nURLs:")
    urls = app.get('urls', {})
    url_dev = get_input("  Development URL", urls.get('development', ''))
    url_staging = get_input("  Staging URL", urls.get('staging', ''))
    url_prod = get_input("  Production URL", urls.get('production', ''))
    url_other = get_input("  Other URL", urls.get('other', ''))

    # Rebuild URLs dict
    new_urls = {}
    if url_dev:
        new_urls['development'] = url_dev
    if url_staging:
        new_urls['staging'] = url_staging
    if url_prod:
        new_urls['production'] = url_prod
    if url_other:
        new_urls['other'] = url_other
    app['urls'] = new_urls

    app['repository'] = get_input("\nRepository URL", app.get('repository', ''))
    app['tech_stack'] = get_input("Technology stack", app.get('tech_stack', ''))

    print(f"\nStatus (current: {app['status']}):")
    print("  1) Development")
    print("  2) Staging")
    print("  3) Production")
    print("  4) Archived")
    status_choice = get_input("Choose status", "")
    if status_choice:
        status_map = {
            "1": "development",
            "2": "staging",
            "3": "production",
            "4": "archived"
        }
        app['status'] = status_map.get(status_choice, app['status'])

    app['notes'] = get_input("\nNotes", app.get('notes', ''))

    # Update timestamp
    app['updated_at'] = datetime.now().isoformat()

    save_apps(data)
    print()
    print_success(f"App '{app['name']}' updated successfully!")
    print()


def remove_app(app_id: str):
    """Remove an app from the tracker"""
    data = load_apps()
    app = next((a for a in data['apps'] if a['id'] == app_id), None)

    if not app:
        print_error(f"App with ID '{app_id}' not found.")
        return

    print_warning(f"About to remove app: {app['name']} ({app_id})")
    confirm = get_input("Type 'yes' to confirm")

    if confirm.lower() != 'yes':
        print_info("Removal cancelled.")
        return

    data['apps'] = [a for a in data['apps'] if a['id'] != app_id]
    save_apps(data)

    print_success(f"App '{app['name']}' removed successfully!")
    print()


def export_markdown():
    """Export apps list to markdown format"""
    data = load_apps()
    apps = data['apps']

    if not apps:
        print_info("No apps to export.")
        return

    output_file = SCRIPT_DIR / "apps-list.md"

    with open(output_file, 'w') as f:
        f.write("# My Apps\n\n")
        f.write(f"*Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*\n\n")

        # Group by status
        statuses = ['production', 'staging', 'development', 'archived']
        for status in statuses:
            status_apps = [app for app in apps if app['status'] == status]
            if status_apps:
                f.write(f"## {status.title()}\n\n")
                for app in status_apps:
                    f.write(f"### {app['name']}\n\n")
                    if app.get('description'):
                        f.write(f"{app['description']}\n\n")
                    if app.get('urls'):
                        f.write("**URLs:**\n")
                        for env, url in app['urls'].items():
                            f.write(f"- {env.title()}: {url}\n")
                        f.write("\n")
                    if app.get('repository'):
                        f.write(f"**Repository:** {app['repository']}\n\n")
                    if app.get('tech_stack'):
                        f.write(f"**Tech Stack:** {app['tech_stack']}\n\n")
                    if app.get('notes'):
                        f.write(f"**Notes:** {app['notes']}\n\n")
                    f.write("---\n\n")

    print_success(f"Apps exported to {output_file}")
    print()


def print_usage():
    """Print usage information"""
    print(f"""
{Colors.BOLD}App Tracker{Colors.NC} - Keep track of your applications

{Colors.BOLD}Usage:{Colors.NC}
  {sys.argv[0]} <command> [arguments]

{Colors.BOLD}Commands:{Colors.NC}
  {Colors.GREEN}add{Colors.NC}                    Add a new app
  {Colors.GREEN}list{Colors.NC} [status]         List all apps (optionally filter by status)
  {Colors.GREEN}view{Colors.NC} <app-id>         View detailed info about an app
  {Colors.GREEN}edit{Colors.NC} <app-id>         Edit an existing app
  {Colors.GREEN}remove{Colors.NC} <app-id>       Remove an app
  {Colors.GREEN}export{Colors.NC}                Export apps list to markdown
  {Colors.GREEN}help{Colors.NC}                  Show this help message

{Colors.BOLD}Status filters:{Colors.NC}
  development, staging, production, archived

{Colors.BOLD}Examples:{Colors.NC}
  {sys.argv[0]} add
  {sys.argv[0]} list
  {sys.argv[0]} list production
  {sys.argv[0]} view my-app
  {sys.argv[0]} edit my-app
  {sys.argv[0]} export

{Colors.BOLD}Data file:{Colors.NC} {DATA_FILE}
""")


def main():
    """Main entry point"""
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(0)

    command = sys.argv[1].lower()

    if command in ['help', '-h', '--help']:
        print_usage()
    elif command == 'add':
        add_app()
    elif command == 'list':
        filter_status = sys.argv[2] if len(sys.argv) > 2 else None
        list_apps(filter_status)
    elif command == 'view':
        if len(sys.argv) < 3:
            print_error("Please provide an app ID")
            print(f"Usage: {sys.argv[0]} view <app-id>")
            sys.exit(1)
        view_app(sys.argv[2])
    elif command == 'edit':
        if len(sys.argv) < 3:
            print_error("Please provide an app ID")
            print(f"Usage: {sys.argv[0]} edit <app-id>")
            sys.exit(1)
        edit_app(sys.argv[2])
    elif command == 'remove':
        if len(sys.argv) < 3:
            print_error("Please provide an app ID")
            print(f"Usage: {sys.argv[0]} remove <app-id>")
            sys.exit(1)
        remove_app(sys.argv[2])
    elif command == 'export':
        export_markdown()
    else:
        print_error(f"Unknown command: {command}")
        print(f"Run '{sys.argv[0]} help' for usage information")
        sys.exit(1)


if __name__ == "__main__":
    main()
