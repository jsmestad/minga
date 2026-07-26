defmodule MingaEditor.Effects.ExternalFormat do
  @moduledoc """
  Latest-wins external formatting effect keyed by Buffer process identity.

  The queued request carries only the Buffer pid and formatter specification.
  The worker snapshots content and version when it starts, then the Editor
  applies formatted content with Buffer's atomic replace-if-version operation.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Commands.BufferManagement
  alias Minga.Buffer
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.ExternalFormatResult
  alias MingaEditor.Effects.Feedback, as: EffectFeedback
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Operation
  @enforce_keys [:buffer, :formatter]
  defstruct [:buffer, :formatter, :continuation]

  @type t :: %__MODULE__{
          buffer: pid(),
          formatter: Minga.Editing.Formatter.formatter_spec(),
          continuation: BufferManagement.save_continuation() | nil
        }

  @doc "Builds a latest-wins request for a Buffer process and existing operation identity."
  @spec request(
          pid(),
          Minga.Editing.Formatter.formatter_spec(),
          Operation.id(),
          BufferManagement.save_continuation() | nil
        ) ::
          Request.t()
  def request(buffer, formatter, operation_id, continuation \\ nil) when is_pid(buffer) do
    Request.new(
      %__MODULE__{buffer: buffer, formatter: formatter, continuation: continuation},
      {:buffer, buffer},
      Policy.latest_wins(),
      operation_id: operation_id
    )
  end

  @impl true
  @spec run(t()) :: {:ok, ExternalFormatResult.t()} | {:error, term()}
  def run(%__MODULE__{buffer: buffer, formatter: formatter}) do
    {content, version} = Buffer.content_with_version(buffer)
    file_name = (Buffer.file_path(buffer) || "scratch") |> Path.basename()

    case Minga.Editing.format(content, formatter) do
      {:ok, formatted} ->
        {:ok, ExternalFormatResult.new(buffer, version, formatted, file_name)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          value: {:queued, queue},
          request: %{operation_id: id}
        } = outcome
      ) do
    {EffectFeedback.queued(state, id, "Format queued", queue), outcome}
  end

  def apply(state, %Outcome{value: :running, request: %{operation_id: id}} = outcome) do
    {EffectFeedback.running(state, id, "Formatting…"), outcome}
  end

  def apply(
        state,
        %Outcome{value: {:completed, %ExternalFormatResult{} = result}} = outcome
      ) do
    apply_formatted_content(state, outcome, result)
  end

  def apply(
        state,
        %Outcome{value: {:failed, :timeout}, request: %{operation_id: id}} = outcome
      ) do
    terminalize(
      EffectFeedback.finished(state, id, :timeout, "Format timed out"),
      outcome,
      {:failed, :timeout}
    )
  end

  def apply(
        state,
        %Outcome{value: {:failed, reason}, request: %{operation_id: id}} = outcome
      ) do
    message = format_failure_message(reason)
    Minga.Log.warning(:editor, message)

    terminalize(EffectFeedback.finished(state, id, :error, message), outcome, {:failed, reason})
  end

  def apply(
        state,
        %Outcome{value: {:canceled, :superseded}, request: %{operation_id: id}} = outcome
      ) do
    terminalize(EffectFeedback.finished(state, id, :stale, "Format replaced"), outcome, :canceled)
  end

  def apply(state, %Outcome{value: {:canceled, _reason}, request: %{operation_id: id}} = outcome) do
    terminalize(
      EffectFeedback.finished(state, id, :canceled, "Format canceled"),
      outcome,
      :canceled
    )
  end

  def apply(state, %Outcome{value: {:stale, _reason}, request: %{operation_id: id}} = outcome) do
    terminalize(
      EffectFeedback.finished(state, id, :stale, "Buffer changed, format skipped"),
      outcome,
      :stale
    )
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec apply_formatted_content(EditorState.t(), Outcome.t(), ExternalFormatResult.t()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_formatted_content(state, outcome, result) do
    with :ok <- admit_worker_result(outcome.request.effect.continuation, result),
         {:ok, committed_version} <- replace_if_current(result) do
      Minga.Log.info(:editor, "Formatted: #{result.file_name}")

      terminalize(
        EffectFeedback.finished(state, outcome.request.operation_id, :success, "Formatted"),
        outcome,
        {:committed, committed_version}
      )
    else
      :stale ->
        stale_format(state, outcome)

      {:error, :stale} ->
        stale_format(state, outcome)

      {:error, :read_only} ->
        failed_format(state, outcome, :read_only, "Buffer is read-only, format skipped")

      {:error, :not_alive} ->
        failed_format(state, outcome, :buffer_closed, "Buffer closed, format skipped")
    end
  end

  defp replace_if_current(%ExternalFormatResult{} = result) do
    Buffer.replace_content_if_version(result.buffer, result.version, result.content, :user)
  catch
    :exit, _reason -> {:error, :not_alive}
  end

  defp admit_worker_result({:save_after_format, _buf, requested_version, _action}, result) do
    if result.version == requested_version, do: :ok, else: :stale
  end

  defp admit_worker_result(nil, _result), do: :ok

  defp stale_format(state, outcome) do
    outcome = Outcome.stale(outcome, :buffer_version_changed)

    terminalize(
      EffectFeedback.finished(
        state,
        outcome.request.operation_id,
        :stale,
        "Buffer changed, format skipped"
      ),
      outcome,
      :stale
    )
  end

  defp failed_format(state, outcome, reason, message) do
    outcome = Outcome.failed(outcome.request, reason)
    terminal_reason = if reason == :buffer_closed, do: :not_alive, else: reason

    terminalize(
      EffectFeedback.finished(state, outcome.request.operation_id, :error, message),
      outcome,
      {:failed, terminal_reason}
    )
  end

  @spec terminalize(EditorState.t(), Outcome.t(), BufferManagement.format_terminal()) ::
          {EditorState.t(), Outcome.t()}
  defp terminalize(state, %{request: %{effect: %{continuation: nil}}} = outcome, _terminal),
    do: {state, outcome}

  defp terminalize(
         state,
         %{request: %{effect: %{continuation: continuation}}} = outcome,
         terminal
       ) do
    {BufferManagement.continue_after_format(state, continuation, terminal), outcome}
  end

  @spec format_failure_message(term()) :: String.t()
  defp format_failure_message({:worker_exit, reason}),
    do: "Format worker failed: #{inspect(reason)}"

  defp format_failure_message({:start_failed, reason}),
    do: "Format worker failed to start: #{inspect(reason)}"

  defp format_failure_message(reason) when is_binary(reason), do: "Format error: #{reason}"
  defp format_failure_message(reason), do: "Format error: #{inspect(reason)}"
end
