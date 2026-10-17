// VS Code client for the Bea language server (`bea lsp`).
//
// The server wraps `gleam lsp`, so Gleam must be installed. Diagnostics,
// hover, go to definition, references, rename, completion, signature help,
// formatting and document symbols all work on `.bea` files.

const vscode = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function serverOptions() {
  const config = vscode.workspace.getConfiguration("bea");
  const command = config.get("path") || "bea";
  const env = { ...process.env };
  const gleam = config.get("gleamPath");
  if (gleam) env.BEA_GLEAM = gleam;
  return {
    run: { command, args: ["lsp"], transport: TransportKind.stdio, options: { env } },
    debug: {
      command,
      args: ["lsp"],
      transport: TransportKind.stdio,
      options: { env: { ...env, BEA_LSP_LOG: "1" } },
    },
  };
}

function clientOptions() {
  return {
    documentSelector: [{ scheme: "file", language: "bea" }],
    synchronize: {
      // Changes made outside the editor (git checkout, codegen, ...) still
      // reach the server.
      fileEvents: vscode.workspace.createFileSystemWatcher(
        "**/{*.bea,bea.toml,src/**/*.gleam,src/**/*.erl,src/**/*.mjs}"
      ),
    },
    outputChannelName: "Bea Language Server",
  };
}

async function start() {
  client = new LanguageClient("bea", "Bea Language Server", serverOptions(), clientOptions());
  try {
    await client.start();
  } catch (error) {
    vscode.window.showErrorMessage(
      `Could not start the Bea language server (${error.message}). ` +
        "Check that `bea` and `gleam` are installed, or set `bea.path`."
    );
  }
}

async function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("bea.restartServer", async () => {
      if (client) await client.stop();
      await start();
    }),
    vscode.workspace.onDidChangeConfiguration(async (event) => {
      if (event.affectsConfiguration("bea.path") || event.affectsConfiguration("bea.gleamPath")) {
        if (client) await client.stop();
        await start();
      }
    })
  );
  await start();
}

async function deactivate() {
  if (client) await client.stop();
}

module.exports = { activate, deactivate };
