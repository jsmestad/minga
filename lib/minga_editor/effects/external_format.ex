defmodule MingaEditor.Effects.ExternalFormat do
  @moduledoc """
  Latest-wins external formatting effect keyed by Buffer process identity.

  The queued request carries only the Buffer pid and formatter specification.
  The worker snapshots content and version when it starts, then the Editor
  applies formatted content with Buffer's atomic replace-if-version operation.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.ExternalFormatResult
  alias MingaEditor.Effects.Feedback, as: EffectFeedback
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Operation
  @enforce_keys [:buffer, :formatter]
  defstruct [:buffer, :formatter]

  @type t :: %__MODULE__{
          buffer: pid(),
          formatter: Minga.Editing.Formatter.formatter_spec()
        }

  @doc "Builds a latest-wins request for a Buffer process and existing operation identity."
  @spec request(pid(), Minga.Editing.Formatter.formatter_spec(), Operation.id()) :: Request.t()
  def request(buffer, formatter, operation_id) when is_pid(buffer) do
    Request.new(
      %__MODULE__{buffer: buffer, formatter: formatter},
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
    {EffectFeedback.finished(state, id, :timeout, "Format timed out"), outcome}
  end

  def apply(
        state,
        %Outcome{value: {:failed, reason}, request: %{operation_id: id}} = outcome
      ) do
    message = format_failure_message(reason)
    Minga.Log.warning(:editor, message)

    {EffectFeedback.finished(state, id, :error, message), outcome}
  end

  def apply(
        state,
        %Outcome{value: {:canceled, :superseded}, request: %{operation_id: id}} = outcome
      ) do
    {EffectFeedback.finished(state, id, :stale, "Format replaced"), outcome}
  end

  def apply(state, %Outcome{value: {:canceled, _reason}, request: %{operation_id: id}} = outcome) do
    {EffectFeedback.finished(state, id, :canceled, "Format canceled"), outcome}
  end

  def apply(state, %Outcome{value: {:stale, _reason}, request: %{operation_id: id}} = outcome) do
    {EffectFeedback.finished(state, id, :stale, "Buffer changed, format skipped"), outcome}
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec apply_formatted_content(EditorState.t(), Outcome.t(), ExternalFormatResult.t()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_formatted_content(state, outcome, result) do
    case replace_if_current(result) do
      :ok ->
        Minga.Log.info(:editor, "Formatted: #{result.file_name}")

        {EffectFeedback.finished(state, outcome.request.operation_id, :success, "Formatted"),
         outcome}

      {:error, :stale} ->
        outcome = Outcome.stale(outcome, :buffer_version_changed)

        {EffectFeedback.finished(
           state,
           outcome.request.operation_id,
           :stale,
           "Buffer changed, format skipped"
         ), outcome}

      {:error, :read_only} ->
        outcome = Outcome.failed(outcome.request, :read_only)

        {EffectFeedback.finished(
           state,
           outcome.request.operation_id,
           :error,
           "Buffer is read-only, format skipped"
         ), outcome}

      {:error, :not_alive} ->
        outcome = Outcome.failed(outcome.request, :buffer_closed)

        {EffectFeedback.finished(
           state,
           outcome.request.operation_id,
           :error,
           "Buffer closed, format skipped"
         ), outcome}
    end
  end

  @spec replace_if_current(ExternalFormatResult.t()) ::
          :ok | {:error, :stale | :read_only | :not_alive}
  defp replace_if_current(%ExternalFormatResult{} = result) do
    Buffer.replace_content_if_version(result.buffer, result.version, result.content, :user)
  catch
    :exit, _reason -> {:error, :not_alive}
  end

  @spec format_failure_message(term()) :: String.t()
  defp format_failure_message({:worker_exit, reason}),
    do: "Format worker failed: #{inspect(reason)}"

  defp format_failure_message({:start_failed, reason}),
    do: "Format worker failed to start: #{inspect(reason)}"

  defp format_failure_message(reason) when is_binary(reason), do: "Format error: #{reason}"
  defp format_failure_message(reason), do: "Format error: #{inspect(reason)}"
end
