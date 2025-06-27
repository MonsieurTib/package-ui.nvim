# package-ui.nvim

A modern, intuitive package manager UI for Neovim that provides a unified interface for managing dependencies across different ecosystems.

Supports npm (Node.js), Cargo (Rust), RubyGems (Ruby), Mix (Elixir) and Pip (Python) through an elegant multi-panel interface with real-time search and version management.

Manage all your project dependencies directly within Neovim. Browse installed packages, discover new ones, and handle version management without switching contexts.

## ✨ Features

- 🚀 **Multi-ecosystem support**: Supports npm (Node.js), Cargo (Rust), RubyGems (Ruby), and Mix (Elixir) package managers
- 🔍 **Real-time search**: Search packages across registries with instant results
- 📦 **Package management**: Install, uninstall, and update packages with ease
- 📊 **Detailed information**: View comprehensive package details, versions, and dependencies
- ⌨️ **Keyboard-driven**: Full keyboard navigation with intuitive shortcuts
- 🎨 **Beautiful UI**: Clean, modern floating window interface
- 🔄 **Update notifications**: See which installed packages have available updates
- 📋 **Version management**: Browse and install specific package versions

## 📸 Interface Overview

## Npm (Javascript)

<img width="1397" alt="NPM" src="https://github.com/user-attachments/assets/ea992761-0771-46e4-8850-da31ef37b41a" />

## Cargo (Rust)

<img width="1599" alt="Cargo" src="https://github.com/user-attachments/assets/889bf362-94ee-4972-af70-3b3bf52ac775" />

## RubyGems (Ruby)

<img width="1689" alt="Gem" src="https://github.com/user-attachments/assets/1459d782-0c71-40bb-8538-80a04714f9b1" />

## Mix (Elixir) 

<img width="1879" alt="Elixir" src="https://github.com/user-attachments/assets/c9910e4d-e0cc-4fbd-958f-46c878040a1e" />

## Pip (Python)

<img width="1420" alt="python" src="https://github.com/user-attachments/assets/e3b319aa-4249-4bec-9f75-cc6142d21662" />


The UI consists of five main components:
- **Search**: Find packages across registries
- **Installed**: View currently installed packages with update indicators
- **Available**: Browse search results and available packages
- **Versions**: Explore different versions of selected packages
- **Details**: Comprehensive package information including dependencies

## 📋 Requirements

- Neovim >= 0.7.0
- `curl` (for API requests)
- **For NPM projects**: `npm` command available in PATH
- **For Cargo projects**: `cargo` command available in PATH

## 📦 Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "MonsieurTib/package-ui.nvim",
  config = function()
    require("package-ui").setup()
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "MonsieurTib/package-ui.nvim",
  config = function()
    require("package-ui").setup()
  end,
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'MonsieurTib/package-ui.nvim'
```

Then add to your `init.lua`:
```lua
require("package-ui").setup()
```

## 🚀 Usage

### Opening the UI

```vim
:PackageUI
```

Or create a keybinding:
```lua
vim.keymap.set("n", "<leader>pu", "<cmd>PackageUI<cr>", { desc = "Open Package UI" })
```

### Navigation

| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | Navigate between components |
| `j` / `k` | Move up/down in lists |
| `Enter` | Select item / Navigate to versions |
| `i` | Install package |
| `u` | Uninstall package |

### Package Management

1. **Search for packages**: Type in the search box to find packages
2. **Install packages**: Press `Enter` to browse versions, then press `i` to install the selected version
3. **View details**: Select any package to see detailed information
4. **Browse versions**: Press `Enter` on a package to see available versions
5. **Uninstall packages**: Navigate to an installed package (in the "Installed" section) and press `u` to remove it from your project
6. **Update packages**: Install newer versions of packages that show update indicators

## ⚙️ Configuration

### Default Configuration

```lua
require("package-ui").setup({
  -- Configuration options will be added here as the plugin evolves
})
```

## 🛠️ Supported Package Managers

### NPM (Node.js)
- Automatically detects `package.json` files
- Manages dependencies and devDependencies
- Supports version ranges and specific versions
- Shows update notifications for outdated packages

### Cargo (Rust)
- Automatically detects `Cargo.toml` files
- Manages dependencies and dev-dependencies
- Integrates with crates.io registry
- Supports semantic versioning

### Gem (Ruby)
- Automatically detects `Gemfile` files
- Manages gem dependencies from Gemfile and Gemfile.lock
- Integrates with rubygems.org registry
- Supports semantic versioning and version constraints

### Mix (Elixir)
- Automatically detects `mix.exs` files
- Manages dependencies from mix.exs configuration
- Integrates with hex.pm registry
- Supports semantic versioning and version constraints
- Handles both runtime and development dependencies

## 🤝 Contributing

Contributions are welcome! Here are some ways you can help:

1. **Report bugs**: Create issues for any problems you encounter
2. **Request features**: Suggest new package managers or UI improvements
3. **Submit PRs**: Fix bugs or implement new features
4. **Documentation**: Help improve documentation and examples

### Adding New Package Managers

To add support for a new package manager:

1. Create a new service file in `lua/package-ui/services/`
2. Implement the required service interface methods
3. Add detection logic for the package manager's manifest files
4. Test thoroughly with real projects

## 📄 License

This project is licensed under the MIT License

## 🙏 Acknowledgments

- Inspired by the need for better package management UX in Neovim
- Built with the Neovim Lua API
- Uses public package registry APIs (npmjs.com, crates.io)

---

**Made with ❤️ for the Neovim community** 
