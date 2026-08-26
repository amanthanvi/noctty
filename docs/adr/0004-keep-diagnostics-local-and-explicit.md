# Keep diagnostics local and explicit

noctty diagnostics will be generated locally and exported only by an explicit user action, with sensitive terminal, clipboard, environment, command-line, working-directory, raw-config, and dump data excluded by default. This preserves the project's no-telemetry contract while still enabling actionable recovery and support artifacts.
