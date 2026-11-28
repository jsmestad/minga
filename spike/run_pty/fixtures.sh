#!/bin/bash
# Builds throwaway fixtures under $1. Network: npm and cargo registries, docker hub.
set -u
F="$1"; mkdir -p "$F"; cd "$F"
# git: a repo with one commit, one staged change and one unstaged change
if [ ! -d repo ]; then
  mkdir repo && cd repo && git init -q . && git config user.email spike@example.invalid && git config user.name spike
  for i in $(seq 1 40); do echo "line $i" >> a.txt; git add a.txt; git commit -q -m "commit $i"; done
  echo staged >> a.txt; git add a.txt; echo unstaged >> a.txt; cd ..
fi
# mix: one passing and one failing test
if [ ! -d mixp ]; then
  mix new mixp >/dev/null 2>&1
  cat > mixp/test/mixp_test.exs <<'T'
defmodule MixpTest do
  use ExUnit.Case
  test "passes" do assert 1 + 1 == 2 end
  test "fails" do assert %{a: 1, b: "left"} == %{a: 1, b: "right"} end
end
T
fi
# node: vitest and jest with one passing test
if [ ! -d nodep/node_modules ]; then
  mkdir -p nodep && cd nodep && git init -q . 2>/dev/null
  npm init -y >/dev/null 2>&1
  npm install --no-audit --no-fund -D vitest jest >/dev/null 2>&1
  mkdir -p t && echo "const {test,expect}=require('vitest');test('ok',()=>{expect(1).toBe(1)})" > t/a.vitest.test.js
  echo "test('ok',()=>{expect(1).toBe(1)})" > t/a.jest.test.js
  echo "module.exports={testMatch:['**/*.jest.test.js']}" > jest.config.js
  echo "export default {test:{include:['t/*.vitest.test.js']}}" > vitest.config.mjs
  git add -A >/dev/null 2>&1; git -c user.email=s@e.invalid -c user.name=s commit -qm init >/dev/null 2>&1; cd ..
fi
# cargo: hello world with one dependency so there is progress to draw
if [ ! -d cargop ]; then
  cargo new -q cargop 2>/dev/null && (cd cargop && printf 'itoa = "1"\n' >> Cargo.toml)
fi
# docker: a two-step build, second step fails
mkdir -p dockp && printf 'FROM alpine:3.20\nRUN echo step-one && sleep 1\nRUN echo step-two-fails && exit 3\n' > dockp/Dockerfile
# npm install target
mkdir -p npmi && (cd npmi && [ -f package.json ] || npm init -y >/dev/null 2>&1)
echo fixtures-ready
