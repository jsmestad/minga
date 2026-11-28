defmodule MingaEditor.UI.Picker.DiagnosticAttachmentSource do
  @moduledoc "Captures a file's published diagnostics before choosing a local Agent draft."
  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias MingaAgent.DraftAttachment
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.UI.Picker.{Context, Item, SelectionAttachmentTargetSource, Source}

  @max_bytes DraftAttachment.max_bytes()

  @doc "Opens the destination picker for diagnostics from the active file."
  @spec open(State.t()) :: State.t()
  def open(%State{workspace: %{keymap_scope: :editor, buffers: %{active: buffer}}} = state)
      when is_pid(buffer) do
    open_buffer(state, buffer)
  end

  def open(%State{} = state),
    do: NoticeWorkflow.publish(state, "Open a file before attaching diagnostics.")

  @doc "Opens the destination picker for the named buffer, independent of keyboard focus."
  @spec open_buffer(State.t(), pid()) :: State.t()
  def open_buffer(state, buffer) do
    case {Buffer.storage(buffer), Buffer.file_path(buffer)} do
      {{:remote, _, _}, _path} ->
        NoticeWorkflow.publish(state, "Diagnostics snapshots are only available for local files.")

      {:local, path} when is_binary(path) ->
        PickerUI.open(state, __MODULE__, %{path: path})

      {:local, nil} ->
        NoticeWorkflow.publish(state, "Open a file before attaching diagnostics.")
    end
  catch
    :exit, _reason ->
      NoticeWorkflow.publish(state, "The diagnostic source is no longer available.")
  end

  @impl true
  @spec title() :: String.t()
  def title, do: "Attach diagnostics to Agent"

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context), do: []

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{picker_ui: %{context: %{path: path}}} = context) do
    with {:ok, snapshot} <- capture(path) do
      items =
        context
        |> Context.with_picker_context(%{source: snapshot})
        |> SelectionAttachmentTargetSource.candidates()

      case items do
        [] -> {:error, "Open a local Agent composer before attaching diagnostics."}
        [_ | _] -> {:ok, items, %{}}
      end
    end
  end

  @impl true
  @spec on_select(Item.t(), State.t()) :: State.t()
  def on_select(item, state), do: SelectionAttachmentTargetSource.on_select(item, state)

  @spec capture(String.t()) :: {:ok, DraftAttachment.text_snapshot()} | {:error, String.t()}
  defp capture(path) do
    case Diagnostics.snapshot(SyncServer.path_to_uri(path)) do
      {_revision, []} ->
        {:error, "No published diagnostics for this file."}

      {_revision, diagnostics} ->
        case format_rows(diagnostics, [], 0) do
          {:ok, text} -> {:ok, {:diagnostics, path, Path.basename(path), text}}
          {:error, :too_large} -> {:error, "Diagnostics exceed the 32 KiB snapshot limit."}
        end
    end
  catch
    :exit, _reason -> {:error, "Diagnostics are unavailable."}
  end

  @spec format_rows([Diagnostic.t()], [iodata()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, :too_large}
  defp format_rows([], rows, _size), do: {:ok, IO.iodata_to_binary(Enum.reverse(rows))}

  defp format_rows([diagnostic | rest], rows, size) do
    %{start_line: line, start_col: column} = diagnostic.range

    row = [
      "#{diagnostic.severity} line #{line + 1}, column #{column + 1} (#{diagnostic.encoding})",
      source_suffix(diagnostic.source),
      ": ",
      diagnostic.message,
      "\n"
    ]

    next_size = size + IO.iodata_length(row)

    if next_size <= @max_bytes,
      do: format_rows(rest, [row | rows], next_size),
      else: {:error, :too_large}
  end

  @spec source_suffix(String.t() | nil) :: iodata()
  defp source_suffix(nil), do: []
  defp source_suffix(source), do: [" [", source, "]"]
end
