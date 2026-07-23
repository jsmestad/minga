defmodule MingaEditor.ConfigReloadEffect do
  @moduledoc """
  Generation-owned typed effect for ordinary configuration reload.

  Reload execution runs under the Editor effect scheduler on one stable resource.
  A zero-queue FIFO policy rejects duplicate requests while one reload is running
  or awaiting Editor application, avoiding concurrent mutation of config-owned
  registries. Completion is applied only after the scheduler grants the current
  Editor generation a claim.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @resource {:config_reload, :ordinary_config}

  @enforce_keys [:reload_module, :reload_args]
  defstruct [:reload_module, :reload_args]

  @type t :: %__MODULE__{reload_module: module(), reload_args: [term()]}
  @type reload_result :: :ok | {:error, String.t()}

  @doc "Builds a request on the single bounded config-reload resource."
  @spec request() :: Request.t()
  @spec request(module()) :: Request.t()
  @spec request(module(), [term()]) :: Request.t()
  def request(reload_module \\ Minga.Config, reload_args \\ [])
      when is_atom(reload_module) and is_list(reload_args) do
    effect = %__MODULE__{reload_module: reload_module, reload_args: reload_args}
    Request.new(effect, @resource, Policy.fifo(0))
  end

  @impl true
  @spec run(t()) :: {:ok, reload_result()} | {:error, term()}
  def run(%__MODULE__{reload_module: reload_module, reload_args: reload_args}) do
    {:ok, apply(reload_module, :reload, reload_args)}
  rescue
    exception -> {:error, {:config_reload_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:config_reload_failure, kind, reason}}
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{value: {:completed, result}} = outcome) do
    {finish(state, result), outcome}
  end

  def apply(state, %Outcome{value: {:failed, reason}} = outcome) do
    {finish(state, {:error, failure_message(reason)}), outcome}
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _payload}})
      when status in [:completed, :failed],
      do: true

  def render?(%Outcome{}), do: false

  @doc "Applies user feedback for a completed reload to the current Editor state."
  @spec finish(EditorState.t(), reload_result()) :: EditorState.t()
  def finish(state, :ok) do
    Minga.Log.info(:editor, "Config reloaded")
    NoticeWorkflow.publish(state, "Config reloaded")
  end

  def finish(state, {:error, message}) when is_binary(message) do
    Minga.Log.warning(:config, "Config reload error: #{message}")
    NoticeWorkflow.publish(state, "Config reload error: #{message}")
  end

  @spec failure_message(term()) :: String.t()
  defp failure_message({:config_reload_exception, message}), do: message

  defp failure_message({:config_reload_failure, kind, reason}),
    do: "#{kind}: #{inspect(reason)}"

  defp failure_message(reason), do: inspect(reason)
end
