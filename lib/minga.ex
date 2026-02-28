defmodule Minga do
  @moduledoc """
  Minga — a BEAM-powered modal text editor.

  Minga uses the Erlang VM's actor model for fault-tolerant editor internals
  and a Zig process (via BEAM Port) for terminal rendering. The architecture
  provides full isolation: if the renderer crashes, the supervisor restarts
  it and re-renders without losing buffer state.

  ## Architecture

      BEAM (Elixir)              Zig (libvaxis)
      ─────────────              ──────────────
      Buffer GenServer    ◄───►  Terminal rendering
      Modal FSM                  Raw input capture
      Keymap / Which-Key         Screen drawing
      Command registry
      Editor orchestration
      Supervisor tree

  ## Quick Start

      mix minga path/to/file.ex
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the current Minga version."
  @spec version() :: String.t()
  def version, do: @version
end
