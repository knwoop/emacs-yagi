# emacs-yagi

Emacs package for AI assistance using [yagi](https://github.com/mattn/yagi).

## Requirements

- Emacs 27.1+
- [yagi](https://github.com/mattn/yagi) executable in PATH
- API key configured via environment variable

## Installation

### Using use-package (with vc)

Emacs 29+ built-in:

```elisp
(use-package yagi
  :vc (:url "https://github.com/knwoop/emacs-yagi" :branch "main")
  :config
  (yagi-mode 1))
```

### Using leaf.el (with vc)

```elisp
(leaf yagi
  :vc (:url "https://github.com/knwoop/emacs-yagi" :branch "main")
  :global-minor-mode yagi-mode)
```

### Manual

```bash
git clone https://github.com/knwoop/emacs-yagi ~/.emacs.d/site-lisp/emacs-yagi
```

Add to your `init.el`:

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-yagi")
(require 'yagi)
(yagi-mode 1)
```

## Configuration

### API Key (Required)

Set your API key in your shell profile (`.bashrc`, `.zshrc`, etc.):

```bash
export OPENAI_API_KEY="your-key-here"
# or
export ANTHROPIC_API_KEY="your-key-here"
# or
export GEMINI_API_KEY="your-key-here"
```

### Package Settings

```elisp
;; Path to yagi executable (default: "yagi")
(setq yagi-executable "yagi")

;; Model to use (default: "openai")
;; Can also be set via YAGI_MODEL environment variable
(setq yagi-model "openai")

;; Show prompt in response buffer (default: t)
(setq yagi-show-prompt t)
```

## Commands

| Command | Description | Region Required |
|---------|-------------|----------------|
| `M-x yagi-chat` | Chat with AI (with optional code context) | No |
| `M-x yagi-prompt` | Ask AI a question | No |
| `M-x yagi-explain` | Explain selected code | Yes |
| `M-x yagi-refactor` | Refactor selected code | Yes |
| `M-x yagi-comment` | Add comments to selected code | Yes |
| `M-x yagi-fix` | Fix bugs in selected code | Yes |
| `M-x yagi-apply` | Apply pending refactored code | No |

## Default Key Bindings

When `yagi-mode` is enabled, the following keybindings are available under the `C-c Y` prefix:

| Key | Command |
|-----|---------|
| `C-c Y c` | `yagi-chat` |
| `C-c Y p` | `yagi-prompt` |
| `C-c Y e` | `yagi-explain` |
| `C-c Y r` | `yagi-refactor` |
| `C-c Y m` | `yagi-comment` |
| `C-c Y f` | `yagi-fix` |

## Usage Examples

1. Select a region and press `C-c Y e` to explain the code
2. Select code and run `M-x yagi-chat RET how can I improve this? RET`
3. Run `M-x yagi-prompt RET what is the time complexity of quicksort? RET`
4. Select code, `C-c Y r` to refactor, review in response buffer, press `a` to apply
5. Select code, `C-c Y f` to fix bugs, confirm with `y` to apply

## Supported Providers

yagi supports many AI providers. Set the corresponding API key environment variable:

- OpenAI (`OPENAI_API_KEY`)
- Anthropic (`ANTHROPIC_API_KEY`)
- Google Gemini (`GEMINI_API_KEY`)
- DeepSeek (`DEEPSEEK_API_KEY`)
- Groq (`GROQ_API_KEY`)
- xAI (`XAI_API_KEY`)
- Mistral (`MISTRAL_API_KEY`)
- Perplexity (`PERPLEXITY_API_KEY`)
- Cerebras (`CEREBRAS_API_KEY`)
- Cohere (`COHERE_API_KEY`)
- OpenRouter (`OPENROUTER_API_KEY`)
- SambaNova (`SAMBANOVA_API_KEY`)
- GLM (`GLM_API_KEY`)

## Troubleshooting

### Error: yagi executable not found

Make sure yagi is installed and in your PATH:

```bash
# Install yagi
go install github.com/mattn/yagi@latest

# Verify
which yagi
```

### Error: yagi exited with status 1

Make sure your API key environment variable is set:

```bash
# Check if key is set
echo $OPENAI_API_KEY

# If not set, add to your shell profile
export OPENAI_API_KEY="your-key-here"
```

If running Emacs from a GUI launcher, environment variables from your shell may not be available. Consider using [exec-path-from-shell](https://github.com/purcell/exec-path-from-shell) to inherit them.

## Related Projects

- [yagi](https://github.com/mattn/yagi) - The CLI tool this package uses
- [vim-yagi](https://github.com/yagi-agent/vim-yagi) - Vim plugin for yagi

## License

MIT
