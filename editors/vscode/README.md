# Bea for VS Code

Syntax highlighting plus the Bea language server: diagnostics (Bea syntax
errors and Gleam type errors mapped back onto your `.bea` code), hover,
go to definition, references, rename, completion, signature help, formatting
and document symbols.

Completion works while you type (after `module.`, inside unfinished calls),
offers functions from modules you haven't imported yet and adds the import,
and completes calls as `name(|)` with the signature popping up. Signature help
shows parameter names and follows the argument you are on. Go to definition
and hover on `@external(...)` open the Erlang / JavaScript function.

Settings:

- `bea.path`, `bea.gleamPath`: where the executables are
- `bea.completion.callParentheses` (default on): complete functions with `()`

Commands: **Bea: Restart Language Server**, **Bea: Show Generated Gleam**.

The extension turns off VS Code's word based suggestions for `.bea` files, so
completions come from the language server only.

Requirements: `bea` and `gleam` on your PATH (or set `bea.path` /
`bea.gleamPath`).

Build the extension:

```sh
npm install
npx vsce package   # produces bea-vscode-<version>.vsix
code --install-extension bea-vscode-*.vsix
```
