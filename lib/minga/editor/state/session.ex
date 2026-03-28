defmodule Minga.Editor.State.Session do
  @moduledoc """
  Session persistence state for the Editor.

  Groups the Editor's session-related fields into a focused sub-struct:
  the periodic save timer and the directory paths for session files and
  swap files. These are set once at startup and only the timer mutates
  during the Editor's lifetime.

  All mutations go through functions on this module.
  """

  @type t :: %__MODULE__{
          timer: reference() | nil,
          swap_dir: String.t() | nil,
          session_dir: String.t() | nil
        }

  defstruct timer: nil,
            swap_dir: nil,
            session_dir: nil

  @doc "Creates a new session state from startup options."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      swap_dir: Keyword.get(opts, :swap_dir),
      session_dir: Keyword.get(opts, :session_dir)
    }
  end

  @doc "Returns keyword options for `Minga.Session` functions."
  @spec session_opts(t()) :: keyword()
  def session_opts(%__MODULE__{session_dir: dir}) do
    [session_dir: dir]
  end

  @doc "Returns keyword options for swap recovery functions."
  @spec swap_opts(t()) :: keyword()
  def swap_opts(%__MODULE__{swap_dir: dir}) do
    [swap_dir: dir]
  end

  # ── Timer management ─────────────────────────────────────────────────────

  @session_save_interval_ms 30_000

  @doc "Starts the periodic session save timer. No-op if session_dir is nil."
  @spec start_timer(t()) :: t()
  def start_timer(%__MODULE__{session_dir: nil} = session), do: session

  def start_timer(%__MODULE__{} = session) do
    ref = Process.send_after(self(), :save_session, @session_save_interval_ms)
    %{session | timer: ref}
  end

  @doc "Cancels the session save timer and clears the reference."
  @spec cancel_timer(t()) :: t()
  def cancel_timer(%__MODULE__{timer: nil} = session), do: session

  def cancel_timer(%__MODULE__{timer: ref} = session) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{session | timer: nil}
  end

  @doc "Restarts the timer: cancels any existing timer and starts a new one."
  @spec restart_timer(t()) :: t()
  def restart_timer(%__MODULE__{} = session) do
    session
    |> cancel_timer()
    |> start_timer()
  end

  @doc "Returns true if session persistence is enabled (session_dir is set)."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{session_dir: nil}), do: false
  def enabled?(%__MODULE__{}), do: true

  @doc "Returns true if swap file recovery is enabled (swap_dir is set)."
  @spec swap_enabled?(t()) :: boolean()
  def swap_enabled?(%__MODULE__{swap_dir: nil}), do: false
  def swap_enabled?(%__MODULE__{}), do: true
end
