# Bea for VS Code

Syntax highlighting plus the Bea language server: diagnostics (Bea syntax
errors and Gleam type errors mapped back onto your `.bea` code), hover,
go to definition, references, rename, completion, signature help, formatting
and document symbols.

Requirements: `bea` and `gleam` on your PATH (or set `bea.path` /
`bea.gleamPath`).

Build the extension:

```sh
npm install
npx vsce package   # produces bea-vscode-<version>.vsix
code --install-extension bea-vscode-*.vsix
```
