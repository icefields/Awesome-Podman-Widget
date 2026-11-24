# Podman Widget for AwesomeWM

A Podman-native rewrite of the Docker widget. Click the Podman icon to list containers and start, stop, pause, unpause, or remove them. It uses Podman's CLI directly and needs no Docker daemon or Docker compatibility alias.

## Requirements

- AwesomeWM
- Podman, available in the same user session as AwesomeWM
- The `podman` executable on `PATH`, unless `executable_name` overrides it

Podman works rootlessly, so the widget does not need root privileges or a running system service.

## Installation

Copy this directory to `~/.config/awesome/podman-widget`, then add the widget to `rc.lua`:

```lua
local podmanWidget = require("podman-widget.podman")

-- Add this to your wibox, for example in the right-side widget list:
podmanWidget(),
```

A customized instance:

```lua
podmanWidget({
    number_of_containers = 5,
    max_widget_width = 800,
}),
```

`docker.lua` is a compatibility loader for an existing configuration that still requires the old module name. New configurations should require `podman-widget.podman`.

## Customization

- `icon`: path to the main icon. Default: `~/.config/awesome/podman-widget/icons/podman.svg`.
- `number_of_containers`: number of most recently created containers to show. Default: `-1`, meaning all containers.
- `executable_name`: Podman executable to run. Default: `podman`; this can also be an absolute path or a wrapper such as `podman-remote`.
- `max_widget_width`: width used for each container row. Default: `1026`.

The widget runs `podman container ls --all --size --last <n>` with a Go template containing `Names`, `ID`, `Image`, `Status`, and `Size`. Lifecycle actions use `podman start`, `stop`, `pause`, `unpause`, and `rm`. Commands are passed to AwesomeWM as argument arrays, without an intermediate shell.

## Tests

The tests load the real widget with AwesomeWM stubs and verify listing, status parsing, icons, and lifecycle commands. They use [Lupa](https://pypi.org/project/lupa/) as an embedded Lua runtime:

```bash
python -m venv .venv
.venv/bin/pip install lupa
.venv/bin/python tests/run.py
```

These are isolated behavior tests. A final smoke test on the target desktop still requires Podman and AwesomeWM.

## Credits

- Original Docker widget by Pavel Makhov and contributors.
- Docker widget fork by Icefields.
- Podman icon from [Simple Icons](https://github.com/simple-icons/simple-icons), recolored to match the existing widget palette.
