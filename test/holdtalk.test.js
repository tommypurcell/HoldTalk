"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const { parseArgs } = require("../bin/holdtalk.js");

const argv = (...args) => ["node", "holdtalk", ...args];

test("no command means start", () => {
  assert.deepEqual(parseArgs(argv()), { command: "start", rebuild: false });
});

test("parses each command", () => {
  for (const command of ["start", "setup", "stop", "status"]) {
    assert.equal(parseArgs(argv(command)).command, command);
  }
});

test("--rebuild is read alongside a command", () => {
  assert.deepEqual(parseArgs(argv("start", "--rebuild")), { command: "start", rebuild: true });
  assert.deepEqual(parseArgs(argv("--rebuild")), { command: "start", rebuild: true });
});

test("--help shows help", () => {
  assert.equal(parseArgs(argv("start", "--help")).command, "help");
});

test("an unknown command is reported, not run", () => {
  const options = parseArgs(argv("launch"));
  assert.equal(options.command, null);
  assert.equal(options.unknown, "launch");
});
