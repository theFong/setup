# Shell Setup

## Prompt Configuration

Custom zsh prompt defined in `~/.zshrc` with color-coded elements:

```zsh
PROMPT='%F{green}%n%f@%F{blue}%m%f:%F{cyan}%~%f $ '
```

| Element | Color | Description |
|---------|-------|-------------|
| `%n` | Green | Username |
| `%m` | Blue | Hostname |
| `%~` | Cyan | Current directory (shortened) |
| `$` | Default | Prompt symbol |

### Format Syntax
- `%F{color}` - Start foreground color
- `%f` - Reset to default color
- `%n` - Username
- `%m` - Hostname (up to first dot)
- `%~` - Current directory, replaces `$HOME` with `~`

## Dependencies

- [Oh My Zsh](https://ohmyz.sh/) - Zsh framework (theme: robbyrussell)
- zsh plugins: `git`

## Installation

1. Install Oh My Zsh
2. Copy `.zshrc` to `$HOME/`
3. Run `source ~/.zshrc`
