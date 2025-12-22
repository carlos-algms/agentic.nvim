# Development Docker Image

Slim Docker image with all PR check tools matching the CI pipeline environment.

## Tools Included

- **Neovim** v0.11.5
- **LuaLS** (Lua Language Server) v3.16.2
- **StyLua** v2.3.1
- **Luacheck** v1.2.0 (installed via luarocks)

## Size Optimization

The image is optimized through several techniques:

- `--no-install-recommends` to avoid unnecessary packages
- Build tools (gcc) are removed after luacheck compilation using
  `apt-get purge --auto-remove`
- `make` is not included (not needed for running the tools)
- APT caches and temporary files are cleaned up in the same layer
- Single-layer RUN commands to minimize image layers

## Build

```bash
docker build -t agentic-nvim-dev repro/
```

## Usage

### Interactive Shell

```bash
docker run --rm -it -v "`pwd`:/workspace" agentic-nvim-dev
```

### Run PR Checks

```bash
# Type checking
docker run --rm -v "`pwd`:/workspace" agentic-nvim-dev make luals

# Linting
docker run --rm -v "`pwd`:/workspace" agentic-nvim-dev make luacheck

# Format checking
docker run --rm -v "`pwd`:/workspace" agentic-nvim-dev make format-check
```

### Run All Checks

```bash
docker run --rm -v "`pwd`:/workspace" agentic-nvim-dev sh -c "make luals && make luacheck && make format-check"
```

## Notes

- Use backticks `` `pwd` `` for the volume mount (not `$PWD` or `$(pwd)`)
- The image supports both ARM64 and x86_64 architectures
- All tools match the versions used in `.github/workflows/pr-check.yml`

