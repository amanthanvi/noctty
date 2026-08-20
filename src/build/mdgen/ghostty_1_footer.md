# FILES

_\$XDG_CONFIG_HOME/noctty/config.ghostty_

: Location of the default configuration file.

_\$HOME/Library/Application Support/io.github.amanthanvi.noctty/config.ghostty_

: **On macOS**, location of the default configuration file. This location takes
precedence over the XDG environment locations.

_\$LOCALAPPDATA/noctty/config.ghostty_

: **On Windows**, if _\$XDG_CONFIG_HOME_ is not set, _\$LOCALAPPDATA_ will be searched
for configuration files.

# ENVIRONMENT

**TERM**

: Defaults to `xterm-ghostty`. Can be configured with the `term` configuration option.

**GHOSTTY_RESOURCES_DIR**

: Where the noctty runtime resources can be found. (The variable name is kept for compatibility with tooling that targets the upstream Ghostty terminal core.)

**XDG_CONFIG_HOME**

: Default location for configuration files.

**$HOME/Library/Application Support/io.github.amanthanvi.noctty**

: **MACOS ONLY** default location for configuration files. This location takes
precedence over the XDG environment locations.

**LOCALAPPDATA**

: **WINDOWS ONLY:** alternate location to search for configuration files.

**GHOSTTY_LOG**

: The `GHOSTTY_LOG` environment variable can be used to control which
destinations receive logs. noctty currently defines two destinations:

: - `stderr` - logging to `stderr`.
: - `macos` - logging to macOS's unified log (has no effect on non-macOS platforms).

: Combine values with a comma to enable multiple destinations. Prefix a
destination with `no-` to disable it. Enabling and disabling destinations
can be done at the same time. Setting `GHOSTTY_LOG` to `true` will enable all
destinations. Setting `GHOSTTY_LOG` to `false` will disable all destinations.

# BUGS

See GitHub issues: <https://github.com/amanthanvi/noctty/issues>

# AUTHOR

Aman Thanvi and contributors <https://github.com/amanthanvi/noctty/graphs/contributors>

# SEE ALSO

**noctty(5)**
