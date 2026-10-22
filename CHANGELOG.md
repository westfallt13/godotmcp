# Changelog

## 1.0.1

- Fix the Hermes dock expanding the editor beyond the window and pushing
  FileSystem and the bottom panel offscreen. Dock content now scrolls within
  the available space, including before its first visible layout.
- Recognize Godot 4.6 resource UID autoload entries as well as older file paths.
  The runtime autoload is recognized after restart and removed on disable.
  Autoloads belonging to other scripts are left untouched.
- Add regression coverage for editor panel bounds, fresh installation, autoload
  ownership, disabling/re-enabling, and editor restart with runtime playtesting.
- Run CI against both Godot 4.5.1 and 4.6.1.

To upgrade, close Godot, replace `addons/hermes_mcp` with the updated addon
folder, and reopen the project. Re-enable Hermes MCP if previously disabled.

## 1.0.0

- Initial native Godot MCP server for editor automation, playtesting and debugging.
