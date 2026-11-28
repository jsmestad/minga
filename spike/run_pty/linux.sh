#!/bin/bash
# Runs inside a Debian-based container with /spike mounted read-only. Linux half of the spike.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq gcc git sudo openssh-client ripgrep vim-tiny nano >/dev/null 2>&1
mkdir -p /w && cp /spike/*.c /spike/*.sh /w/ && cd /w && cc -O2 -Wall -o runpty runpty.c && cc -O2 -Wall -o probe probe.c || exit 1
uname -srm
echo "##### MATRIX"; ./matrix.sh
useradd -m u 2>/dev/null; echo 'u ALL=(ALL) ALL' > /etc/sudoers.d/u
chmod -R a+rx /w
su u -c 'bash -s' <<'U'
cd /w
export TERM=xterm-256color PAGER=cat GIT_PAGER=cat MANPAGER=cat GH_PAGER=cat
F=/tmp/f; mkdir -p $F/repo && cd $F/repo && git init -q . && git config user.email u@example.invalid && git config user.name u
for i in $(seq 1 40); do echo "line $i" >> a.txt; git add a.txt; git commit -q -m "commit $i"; done
echo staged >> a.txt; git add a.txt; echo unstaged >> a.txt
run() { name="$1"; cwd="$2"; to="$3"; shift 3
  for cfg in "yes rw" "no wo"; do ct=${cfg% *}; sl=${cfg#* }
    out=$(cd "$cwd" && /w/runpty --ctty $ct --slave $sl --timeout "$to" -- "$@" 2>/tmp/res | tr -d '\r' | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v '^ *$' | head -3 | cut -c1-140 | paste -sd'|' -)
    printf '%-16s ctty=%-3s %s :: %s\n' "$name" "$ct" "$(sed -e 's/RESULT //' -e 's/ ctty=.*//' /tmp/res)" "$out"
  done; }
echo "##### REAL"
run git-commit-vi   $F/repo 8 env EDITOR=vi git commit
run git-commit-nano $F/repo 8 env EDITOR=nano git commit
run sudo-v          $F 8 sudo -v
run ssh-hostkey     $F 12 ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=ask -o ConnectTimeout=6 -T git@github.com
run rg              $F/repo 8 rg line.1 .
run ls              /usr/bin 8 ls
run git-log         $F/repo 8 git log
run git-diff        $F/repo 8 git diff
run kill-group      $F 3 sh -c 'sleep 300 & sleep 300'
echo "leftover sleeps: $(pgrep -c sleep)"
if command -v npx >/dev/null; then
  mkdir -p $F/nodep && cd $F/nodep && git init -q . && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund -D vitest jest >/dev/null 2>&1
  mkdir -p t && echo "import {test,expect} from 'vitest';test('ok',()=>{expect(1).toBe(1)})" > t/a.vitest.test.mjs
  echo "test('ok',()=>{expect(1).toBe(1)})" > t/a.jest.test.js
  echo "module.exports={testMatch:['**/*.jest.test.js']}" > jest.config.js
  echo "export default {test:{include:['t/*.vitest.test.mjs']}}" > vitest.config.mjs
  echo node_modules > .gitignore; git add -A; git -c user.email=u@example.invalid -c user.name=u commit -qm init
  run vitest-watch $F/nodep 12 npx vitest --watch
  run jest-watchAll $F/nodep 12 npx jest --watchAll
  run jest-plain   $F/nodep 20 npx jest
fi
U
