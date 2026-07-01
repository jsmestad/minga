# shellcheck shell=bash
# Editor-tuned BEAM VM flags, sourced by bin/minga and bin/minga-dev (see
# rel/vm.args.eex). Caller-provided ERL_FLAGS are appended so they can override.
MINGA_ERL_FLAGS="+A 4 +sbwt none +sbwtdcpu none +sbwtdio none +swt very_low +swtdcpu very_low +swtdio very_low +MBas aobf +Mea min +MBacul 0 +hmbs 32768"

export ERL_FLAGS="${MINGA_ERL_FLAGS} ${ERL_FLAGS:-}"
