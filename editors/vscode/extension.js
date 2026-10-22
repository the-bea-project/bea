// VS Code client for the Bea language server (`bea lsp`).
//
// The server wraps `gleam lsp`, so Gleam must be installed. Diagnostics,
// hover, go to definition, references, rename, completion, signature help,
// formatting and document symbols all work on `.bea` files.

const vscode = require("vscode");
const { execFile } = require("child_process");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function beaCommand() {
  return vscode.workspace.getConfiguration("bea").get("path") || "bea";
}

function serverEnv() {
  const env = { ...process.env };
  const gleam = vscode.workspace.getConfiguration("bea").get("gleamPath");
  if (gleam) env.BEA_GLEAM = gleam;
  return env;
}

function serverOptions() {
  const command = beaCommand();
  const env = serverEnv();
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
  const config = vscode.workspace.getConfiguration("bea");
  return {
    documentSelector: [{ scheme: "file", language: "bea" }],
    initializationOptions: {
      completion: { callParentheses: config.get("completion.callParentheses", true) },
      format: { organizeImports: config.get("format.organizeImports", true) },
    },
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

async function restart() {
  if (client) await client.stop();
  await start();
}

// Show the Gleam code the current buffer compiles to (unsaved changes
// included) — handy to understand what Bea does with a piece of syntax.
async function showGeneratedGleam() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "bea") return;
  const source = editor.document.getText();
  const output = await new Promise((resolve) => {
    const child = execFile(
      beaCommand(),
      ["transpile", "--stdin"],
      { env: serverEnv(), maxBuffer: 16 * 1024 * 1024 },
      (error, stdout, stderr) => resolve({ error, stdout, stderr })
    );
    child.stdin.end(source);
  });
  if (output.error && !output.stdout) {
    vscode.window.showErrorMessage(
      "Bea could not compile this file:\n" + (output.stderr || output.error.message)
    );
    return;
  }
  const doc = await vscode.workspace.openTextDocument({ language: "gleam", content: output.stdout });
  await vscode.window.showTextDocument(doc, { viewColumn: vscode.ViewColumn.Beside, preview: true });
}

async function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("bea.restartServer", restart),
    vscode.commands.registerCommand("bea.showGeneratedGleam", showGeneratedGleam),
    vscode.workspace.onDidChangeConfiguration(async (event) => {
      if (
        event.affectsConfiguration("bea.path") ||
        event.affectsConfiguration("bea.gleamPath") ||
        event.affectsConfiguration("bea.completion") ||
        event.affectsConfiguration("bea.format")
      ) {
        await restart();
      }
    })
  );
  await start();
}

async function deactivate() {
  if (client) await client.stop();
}

module.exports = { activate, deactivate };
