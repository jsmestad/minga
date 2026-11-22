defmodule MingaEditor.Extension.RepositoryJob do
  @moduledoc """
  Proposes work for an explicit repository without starting it. Return `{:schedule, state, job}` from an extension command or editor action to submit the proposal. The editor must accept that callback result before a worker can run.

  Each lane admits one job per source. Workers receive immutable arguments rather than editor state. Completion callbacks are discarded after source unload or a project change. Diff loading also requires the originating editor buffer to remain active. File-only commit message generation requires the same active file because that file selects the repository.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Extension.InvocationContext
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.RepositoryJob.Handler
  alias MingaEditor.Shell
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree

  @enforce_keys [:source, :activation, :lane, :root, :handler, :args, :origin]
  defstruct [:source, :activation, :lane, :root, :handler, :args, :origin]

  @type lane :: :remote | :commit_message | :diff_open
  @type result ::
          {:ok, t()} | {:error, :source_unavailable | :invalid_repository | :invalid_arguments}
  @typep origin ::
           {Shell.Identity.t(), String.t() | nil, String.t() | nil, non_neg_integer(),
            pid() | String.t() | nil}
  @opaque t :: %__MODULE__{
            source: CallbackInvoker.source(),
            activation: CodeLease.activation(),
            lane: lane(),
            root: String.t(),
            handler: module(),
            args: term(),
            origin: origin()
          }

  @doc "Proposes work for an absolute repository path. Arguments must be data, not runtime handles."
  @spec propose(EditorAPI.state(), lane(), String.t(), module(), term()) :: result()
  def propose(%EditorState{} = state, lane, root, handler, args)
      when lane in [:remote, :commit_message, :diff_open] and is_binary(root) and is_atom(handler) do
    cond do
      Path.type(root) != :absolute -> {:error, :invalid_repository}
      not data?(args) -> {:error, :invalid_arguments}
      true -> build(state, lane, root, handler, args)
    end
  end

  @spec build(EditorState.t(), lane(), String.t(), module(), term()) :: result()
  defp build(state, lane, root, handler, args) do
    with {:ok, {:extension, _name} = source} <- InvocationContext.current_source(),
         {:ok, activation} <- CodeLease.activation(source, handler) do
      {:ok,
       %__MODULE__{
         source: source,
         activation: activation,
         lane: lane,
         root: Path.expand(root),
         handler: handler,
         args: args,
         origin: origin(state, lane)
       }}
    else
      _unavailable -> {:error, :source_unavailable}
    end
  end

  @doc "Validates a job received from an extension callback before scheduling it."
  @spec cast(term()) :: {:ok, t()} | :error
  def cast(%__MODULE__{} = job), do: {:ok, job}
  def cast(_value), do: :error

  @doc "Returns the owning source and remote job for a retry from that source."
  @spec remote_retry(t()) :: {CallbackInvoker.source(), t()}
  def remote_retry(%__MODULE__{source: source, lane: :remote} = job) do
    case InvocationContext.current_source() do
      {:ok, ^source} -> {source, job}
      _not_owned -> raise ArgumentError, "Git retry must belong to the current extension source"
    end
  end

  @doc "Schedules an admitted extension job, or displays the reason it cannot run."
  @spec submit(EditorState.t(), CallbackInvoker.source(), t()) :: EditorState.t()
  def submit(state, source, %__MODULE__{source: source} = job) do
    with :ok <- admission_status(state, job),
         {:ok, _id, _phase} <- EffectScheduler.schedule(state.effect_scheduler, request(job)) do
      state
    else
      {:error, :queue_full} -> EditorAPI.notice(state, "A repository job is already running")
      {:error, _reason} -> EditorAPI.notice(state, "Repository job was not scheduled")
    end
  end

  def submit(state, _source, %__MODULE__{}),
    do: EditorAPI.notice(state, "Repository job does not belong to this extension")

  @impl true
  @spec run(t()) :: Handler.result()
  def run(%__MODULE__{} = job) do
    case invoke(job, :run, [job.root, job.args], :repository_job) do
      {:ok, {:ok, _value} = result} ->
        result

      {:ok, {:error, _reason} = result} ->
        result

      {:ok, other} ->
        {:error, CallbackInvoker.invalid_return(job.source, job.handler, :run, other)}

      {:error, _failure} = error ->
        error
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{value: {:canceled, :source_canceled}} = outcome), do: {state, outcome}

  def apply(state, %Outcome{request: %{effect: job}, value: :running} = outcome) do
    if function_exported?(job.handler, :on_start, 3) and admission_status(state, job) == :ok do
      {deliver(state, job, :on_start, [job.root, job.args]), outcome}
    else
      {state, outcome}
    end
  end

  def apply(state, %Outcome{request: %{effect: job}, value: {status, _} = value} = outcome)
      when status in [:completed, :failed, :canceled] do
    case admission_status(state, job) do
      :ok ->
        {deliver(state, job, :on_result, [job.root, value, job.args]), outcome}

      {:error, reason} ->
        {stale_feedback(state, job, reason), Outcome.stale(outcome, reason)}
    end
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{
        request: %Request{effect: %__MODULE__{lane: lane}},
        value: {:stale, :repository_changed}
      })
      when lane in [:diff_open, :commit_message],
      do: true

  def render?(%Outcome{value: {status, _}}), do: status in [:completed, :failed, :canceled]
  def render?(%Outcome{value: :running}), do: true

  @spec admission_status(EditorState.t(), t()) :: :ok | {:error, atom()}
  defp admission_status(state, job) do
    cond do
      state.effect_scheduler == nil ->
        {:error, :scheduler_unavailable}

      CodeLease.activation(job.source, job.handler) != {:ok, job.activation} ->
        {:error, :source_unavailable}

      origin(state, job.lane) != job.origin ->
        {:error, :repository_changed}

      true ->
        :ok
    end
  end

  @spec stale_feedback(EditorState.t(), t(), atom()) :: EditorState.t()
  defp stale_feedback(state, %__MODULE__{lane: :diff_open}, :repository_changed),
    do: EditorAPI.notice(state, "Git diff context changed; retry opening the diff")

  defp stale_feedback(state, %__MODULE__{lane: :commit_message}, :repository_changed),
    do: EditorAPI.notice(state, "Commit message result ignored after repository changed")

  defp stale_feedback(state, _job, _reason), do: state

  @spec request(t()) :: Request.t()
  defp request(%__MODULE__{lane: :remote} = job) do
    Request.new(job, {__MODULE__, job.source, :remote}, Policy.fifo(0),
      source: job.source,
      timeout_ms: 120_000,
      activity: :git_syncing
    )
  end

  defp request(%__MODULE__{lane: :commit_message} = job) do
    Request.new(job, {__MODULE__, job.source, :commit_message}, Policy.fifo(0),
      source: job.source,
      timeout_ms: 15_000
    )
  end

  defp request(%__MODULE__{lane: :diff_open} = job) do
    Request.new(job, {__MODULE__, job.source, :diff_open}, Policy.fifo(0),
      source: job.source,
      timeout_ms: 12_000
    )
  end

  @spec deliver(EditorState.t(), t(), atom(), [term()]) :: EditorState.t()
  defp deliver(state, job, callback, args) do
    case invoke(job, callback, [state | args], :repository_job_result) do
      {:ok, %EditorState{} = updated} ->
        updated

      {:ok, other} ->
        _failure = CallbackInvoker.invalid_return(job.source, job.handler, callback, other)
        state

      {:error, _failure} ->
        state
    end
  end

  @spec invoke(t(), atom(), [term()], atom()) :: CallbackInvoker.result(term())
  defp invoke(job, function, args, semantics) do
    CallbackInvoker.invoke_in_activation(
      job.source,
      job.activation,
      job.handler,
      function,
      args,
      semantics
    )
  end

  @spec origin(EditorState.t(), lane()) :: origin()
  defp origin(%EditorState{workspace: %{file_tree: tree}, shell_runtime: shell} = state, lane) do
    {Shell.Runtime.identity(shell), tree.project_root, tree.original_root,
     FileTree.presentation_generation(tree), origin_target(state, lane)}
  end

  @spec origin_target(EditorState.t(), lane()) :: pid() | String.t() | nil
  defp origin_target(state, :diff_open), do: state.workspace.buffers.active

  defp origin_target(state, :commit_message) do
    if EditorAPI.project_root(state) == nil, do: EditorAPI.active_path(state)
  end

  defp origin_target(_state, :remote), do: nil

  @spec data?(term()) :: boolean()
  defp data?(value) when is_atom(value) or is_number(value) or is_bitstring(value), do: true
  defp data?([]), do: true
  defp data?([head | tail]), do: data?(head) and data?(tail)

  defp data?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> data?(key) and data?(item) end)

  defp data?(value) when is_tuple(value), do: tuple_data?(value, tuple_size(value) - 1)
  defp data?(_value), do: false

  @spec tuple_data?(tuple(), integer()) :: boolean()
  defp tuple_data?(_tuple, -1), do: true
  defp tuple_data?(tuple, index), do: data?(elem(tuple, index)) and tuple_data?(tuple, index - 1)
end
