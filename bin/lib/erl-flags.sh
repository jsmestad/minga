# shellcheck shell=bash
# Editor-tuned BEAM VM flags, shared by the launchers (bin/minga, bin/minga-dev).
# See rel/vm.args.eex for the rationale behind each flag. Source this file to
# export ERL_FLAGS with the tuned flags first and any caller-provided ERL_FLAGS
# appended, so a caller can still override:  ERL_FLAGS="+S 2:2" bin/minga ...
#
# This is a sourced snippet, not an executable command; it only sets ERL_FLAGS.
MINGA_ERL_FLAGS="+A 4 +sbwt none +sbwtdcpu none +sbwtdio none +swt very_low +swtdcpu very_low +swtdio very_low +MBas aobf +Mea min +MBacul 0 +hmbs 32768"

export ERL_FLAGS="${MINGA_ERL_FLAGS} ${ERL_FLAGS:-}"
