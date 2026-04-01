defmodule MingaAgent.RuntimeState do
  @moduledoc """
  Domain-only agent session state, independent of any UI.

  Tracks the active session identity, lifecycle status, and
  model/provider info. This struct lives in Layer 1 and can be
  consumed by both the Editor (Layer 2) and headless runtime
  clients without pulling in presentation concerns.

  Presentation state (spinner timers, buffer PIDs, session history)
  lives in `MingaEditor.State.Agent`, which composes this struct.
  """

  @typedoc "Agent lifecycle status."
  @type status :: :idle | :thinking | :tool_executing | :error | nil

  @typedoc "Domain-only agent runtime state."
  @type t :: %__MODULE__{
          active_session_id: String.t() | nil,
          status: status(),
          model_name: String.t() | nil,
          provider_name: String.t() | nil
        }

  defstruct active_session_id: nil,
            status: nil,
            model_name: nil,
            provider_name: nil

  # ── Status ──────────────────────────────────────────────────────────────────

  @doc "Sets the agent lifecycle status."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = rt, status), do: %{rt | status: status}

  @doc "Returns true if the agent is actively working."
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{status: s}) when s in [:thinking, :tool_executing], do: true
  def busy?(%__MODULE__{}), do: false

  # ── Identity ────────────────────────────────────────────────────────────────

  @doc "Sets the active session ID."
  @spec set_session_id(t(), String.t() | nil) :: t()
  def set_session_id(%__MODULE__{} = rt, id), do: %{rt | active_session_id: id}

  @doc "Sets the model name."
  @spec set_model(t(), String.t() | nil) :: t()
  def set_model(%__MODULE__{} = rt, name), do: %{rt | model_name: name}

  @doc "Sets the provider name."
  @spec set_provider(t(), String.t() | nil) :: t()
  def set_provider(%__MODULE__{} = rt, name), do: %{rt | provider_name: name}
end
