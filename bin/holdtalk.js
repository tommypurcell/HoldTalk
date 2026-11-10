#!/usr/bin/env node
// The holdtalk command: builds, installs, and starts the HoldTalk Mac app.
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const packageRoot = path.resolve(__dirname, "..");
const appPath = path.join(os.homedir(), "Applications", "HoldTalk.app");
const modelPath = path.join(os.homedir(), ".config", "holdtalk", "models", "ggml-small.bin");
// Same places Config.swift looks for whisper-cli.
const whisperPaths = [
  "/opt/homebrew/bin/whisper-cli",
  "/usr/local/bin/whisper-cli",
  "/opt/homebrew/bin/whisper-cpp",
  "/usr/local/bin/whisper-cpp",
];

const commands = ["start", "setup", "stop", "status", "help"];

function parseArgs(argv) {
  const args = argv.slice(2);
  const rebuild = args.includes("--rebuild");
  const names = args.filter((arg) => !arg.startsWith("--"));
  const command = names[0] || "start";
  if (args.includes("--help") || args.includes("-h")) return { command: "help", rebuild };
  if (!commands.includes(command)) return { command: null, rebuild, unknown: command };
  return { command, rebuild };
}

function findWhisper() {
  return whisperPaths.find((candidate) => fs.existsSync(candidate)) || null;
}

function hasSwift() {
  return spawnSync("xcrun", ["--find", "swift"], { stdio: "ignore" }).status === 0;
}

function isRunning() {
  return spawnSync("pgrep", ["-x", "HoldTalk"], { stdio: "ignore" }).status === 0;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: "inherit", cwd: packageRoot, ...options });
  if (result.error) throw result.error;
  return result.status === 0;
}

function build() {
  if (!hasSwift()) {
    throw new Error("Swift isn't installed. Run: xcode-select --install");
  }
  console.log("Building HoldTalk. The first build takes a few minutes.");
  if (!run("bash", ["scripts/build-app.sh", "--install"])) {
    throw new Error("The build failed. See the output above.");
  }
}

function warnMissingParts() {
  if (!findWhisper()) {
    console.log("Missing: whisper-cli. Run: holdtalk setup");
  }
  if (!fs.existsSync(modelPath)) {
    console.log("Missing: the speech model. Run: holdtalk setup");
  }
}

function start({ rebuild }) {
  if (process.platform !== "darwin") throw new Error("HoldTalk only runs on macOS.");
  if (isRunning()) {
    console.log("HoldTalk is already running.");
    return;
  }
  if (rebuild || !fs.existsSync(appPath)) build();
  if (!run("open", [appPath])) throw new Error(`Couldn't open ${appPath}`);
  console.log("HoldTalk started. Look for it in the menu bar.");
  warnMissingParts();
}

function setup(options) {
  if (process.platform !== "darwin") throw new Error("HoldTalk only runs on macOS.");
  if (!findWhisper()) {
    console.log("Installing whisper-cpp with Homebrew...");
    if (!run("brew", ["install", "whisper-cpp"])) {
      throw new Error("Couldn't install whisper-cpp. Install Homebrew, then run: brew install whisper-cpp");
    }
  }
  if (!fs.existsSync(modelPath)) {
    if (!run("bash", ["scripts/download-model.sh", "small"])) {
      throw new Error("Couldn't download the speech model.");
    }
  }
  start(options);
}

function stop() {
  if (!isRunning()) {
    console.log("HoldTalk isn't running.");
    return;
  }
  spawnSync("pkill", ["-x", "HoldTalk"]);
  console.log("HoldTalk stopped.");
}

function status() {
  const yesNo = (value) => (value ? "yes" : "no");
  console.log(`App installed: ${yesNo(fs.existsSync(appPath))} (${appPath})`);
  console.log(`Running:       ${yesNo(isRunning())}`);
  console.log(`whisper-cli:   ${findWhisper() || "not found"}`);
  console.log(`Speech model:  ${yesNo(fs.existsSync(modelPath))}`);
}

function help() {
  console.log(`Usage: holdtalk [command]

Commands:
  start     Build if needed, then open HoldTalk (default)
  setup     Install whisper-cpp, download the speech model, then start
  stop      Quit HoldTalk
  status    Show what's installed and running

Options:
  --rebuild   Rebuild the app even if it's already installed`);
}

function main(argv) {
  const options = parseArgs(argv);
  if (options.unknown) {
    console.error(`Unknown command: ${options.unknown}\n`);
    help();
    return 1;
  }
  try {
    switch (options.command) {
      case "start": start(options); break;
      case "setup": setup(options); break;
      case "stop": stop(); break;
      case "status": status(); break;
      case "help": help(); break;
    }
    return 0;
  } catch (error) {
    console.error(error.message);
    return 1;
  }
}

if (require.main === module) {
  process.exitCode = main(process.argv);
}

module.exports = { parseArgs, findWhisper, main };
