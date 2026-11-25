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
  alias MingaEditor.State.Feedback
  alias MingaEditor.State, as: EditorState

  @resource {:config_reload, :ordinary_config}

  @enforce_keys [:reload_module, :reload_args]
  defstruct [:reload_module, :reload_args]

  @type t :: %__MODULE__{reload_module: module(), reload_args: [term()]}
  @type reload_result :: :ok | {:error, String.t()}

  @typedoc """
  What the reload left loaded: `{:loaded, error}` names why the global config file did not evaluate (nil when it did), and `:unchanged` means the reload did not report on the global config, so the last known state stands.
  """
  @type config_state :: {:loaded, String.t() | nil} | :unchanged

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
  @spec run(t()) ::
          {:ok, {reload_result(), config_state(), project_line :: String.t() | nil}}
          | {:error, term()}
  def run(%__MODULE__{reload_module: reload_module, reload_args: reload_args}) do
    result = apply(reload_module, :reload, reload_args)
    # Read here, off the Editor: both ask the loader process.
    {:ok, {result, config_state(reload_module), project_line(reload_module)}}
  rescue
    exception -> {:error, {:config_reload_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:config_reload_failure, kind, reason}}
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{value: {:completed, {result, config_state, project_line}}} = outcome
      ) do
    say_project_config(project_line)
    {finish(state, result, config_state), outcome}
  end

  # A reload that crashed reported nothing about what is loaded, so the last known state stands.
  def apply(state, %Outcome{value: {:failed, reason}} = outcome) do
    {finish(state, {:error, failure_message(reason)}, :unchanged), outcome}
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _payload}})
      when status in [:completed, :failed],
      do: true

  def render?(%Outcome{}), do: false

  @doc """
  Applies user feedback for a completed reload to the current Editor state.

  A clean reload means the config loaded. After an error, `config_state` says whether the global config file evaluated: a reload the loader rejected (a restart is required) or one that crashed leaves the last load, and its state, in place.
  """
  @spec finish(EditorState.t(), reload_result(), config_state()) :: EditorState.t()
  def finish(state, result, config_state \\ :unchanged)

  def finish(state, :ok, _config_state) do
    Minga.Log.info(:editor, "Config reloaded")

    %{state | feedback: Feedback.report_config_load(state.feedback, nil)}
    |> NoticeWorkflow.publish("Config reloaded")
  end

  def finish(state, {:error, message}, config_state) when is_binary(message) do
    Minga.Log.warning(:config, "Config reload error: #{message}")

    state
    |> report_config_state(config_state)
    |> NoticeWorkflow.publish("Config reload error: #{message}")
  end

  # Says in `*Messages*` which folder project-local configuration came from, or why a folder was refused.
  @spec say_project_config(String.t() | nil) :: :ok
  defp say_project_config(nil), do: :ok
  defp say_project_config(line) when is_binary(line), do: Minga.API.message(line)

  # Only the global loader knows about project-local configuration; another reload implementation says nothing.
  @spec project_line(module()) :: String.t() | nil
  defp project_line(Minga.Config), do: Minga.Config.project_config_message()
  defp project_line(_reload_module), do: nil

  @spec report_config_state(EditorState.t(), config_state()) :: EditorState.t()
  defp report_config_state(state, {:loaded, error}),
    do: %{state | feedback: Feedback.report_config_load(state.feedback, error)}

  defp report_config_state(state, :unchanged), do: state

  # Only the global loader reports on the global config; another reload implementation leaves it as it was.
  @spec config_state(module()) :: config_state()
  defp config_state(Minga.Config), do: {:loaded, Minga.Config.config_eval_error()}
  defp config_state(_reload_module), do: :unchanged

  @spec failure_message(term()) :: String.t()
  defp failure_message({:config_reload_exception, message}), do: message

  defp failure_message({:config_reload_failure, kind, reason}),
    do: "#{kind}: #{inspect(reason)}"

  defp failure_message(reason), do: inspect(reason)
end
