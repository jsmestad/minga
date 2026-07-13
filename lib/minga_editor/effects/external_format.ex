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
  alias MingaEditor.State, as: EditorState

  @enforce_keys [:buffer, :formatter]
  defstruct [:buffer, :formatter]

  @type t :: %__MODULE__{
          buffer: pid(),
          formatter: Minga.Editing.Formatter.formatter_spec()
        }

  @doc "Builds a latest-wins request for a Buffer process."
  @spec request(pid(), Minga.Editing.Formatter.formatter_spec()) :: Request.t()
  def request(buffer, formatter) when is_pid(buffer) do
    Request.new(
      %__MODULE__{buffer: buffer, formatter: formatter},
      {:buffer, buffer},
      Policy.latest_wins()
    )
  end

  @impl true
  @spec run(t()) :: {:ok, ExternalFormatResult.t()} | {:error, term()}
  def run(%__MODULE__{buffer: buffer, formatter: formatter}) do
    {content, version} = Buffer.content_with_version(buffer)

    case Minga.Editing.format(content, formatter) do
      {:ok, formatted} -> {:ok, ExternalFormatResult.new(buffer, version, formatted)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{status: :queued} = outcome) do
    {EditorState.set_status(state, "Format queued"), outcome}
  end

  def apply(state, %Outcome{status: :running} = outcome) do
    {EditorState.set_status(state, "Formatting…"), outcome}
  end

  def apply(
        state,
        %Outcome{status: :completed, result: %ExternalFormatResult{} = result} = outcome
      ) do
    apply_formatted_content(state, outcome, result)
  end

  def apply(state, %Outcome{status: :failed, reason: reason} = outcome) do
    message = format_failure_message(reason)
    Minga.Log.warning(:editor, message)
    {EditorState.set_status(state, message), outcome}
  end

  def apply(state, %Outcome{status: :canceled} = outcome) do
    {EditorState.set_status(state, "Format canceled"), outcome}
  end

  def apply(state, %Outcome{status: :stale} = outcome) do
    {EditorState.set_status(state, "Buffer changed, format skipped"), outcome}
  end

  @spec apply_formatted_content(EditorState.t(), Outcome.t(), ExternalFormatResult.t()) ::
          {EditorState.t(), Outcome.t()}
  defp apply_formatted_content(state, outcome, result) do
    case replace_if_current(result) do
      :ok ->
        file_name = (Buffer.file_path(result.buffer) || "scratch") |> Path.basename()
        Minga.Log.info(:editor, "Formatted: #{file_name}")
        {EditorState.set_status(state, "Formatted"), outcome}

      {:error, :stale} ->
        {EditorState.set_status(state, "Buffer changed, format skipped"),
         Outcome.stale(outcome, :buffer_version_changed)}

      {:error, :read_only} ->
        {EditorState.set_status(state, "Buffer is read-only, format skipped"),
         Outcome.failed(outcome.request, :read_only)}

      {:error, :not_alive} ->
        {EditorState.set_status(state, "Buffer closed, format skipped"),
         Outcome.failed(outcome.request, :buffer_closed)}
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
