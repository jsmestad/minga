defmodule MingaEditor.Agent.SelectionAttachment do
  @moduledoc "Captures selected text or the current buffer before choosing an Agent composer destination."

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Buffer.Selection
  alias Minga.Buffer.Span
  alias Minga.Mode.VisualState
  alias MingaEditor.State

  @max_bytes MingaAgent.DraftAttachment.max_bytes()

  @type source :: MingaAgent.DraftAttachment.text_snapshot()
  @type rejection :: :no_selection | :source_too_large | :source_unavailable | :empty_buffer

  @doc "Captures file label and selected bytes from one immutable Buffer document."
  @spec capture(State.t()) :: {:ok, source()} | {:error, rejection()}
  def capture(%State{
        workspace: %{
          keymap_scope: :editor,
          buffers: %{active: buffer},
          editing: %{
            mode: mode,
            mode_state: %VisualState{visual_anchor: anchor, visual_type: kind}
          }
        }
      })
      when mode in [:visual, :visual_line] and is_pid(buffer) and is_tuple(anchor) do
    document = Buffer.snapshot(buffer)

    with {:ok, text} <- text(document, kind, anchor) do
      source = Buffer.file_path(buffer) || "Untitled selection"
      {:ok, {:selection, source, Path.basename(source), text}}
    end
  catch
    :exit, _reason -> {:error, :source_unavailable}
  end

  def capture(%State{}), do: {:error, :no_selection}

  @doc "Captures the current editor buffer, including edits not yet saved to disk."
  @spec capture_buffer(State.t()) :: {:ok, source()} | {:error, rejection()}
  def capture_buffer(%State{workspace: %{keymap_scope: :editor, buffers: %{active: buffer}}})
      when is_pid(buffer) do
    case Buffer.bounded_content_with_path(buffer, @max_bytes) do
      {:ok, "", _path} ->
        {:error, :empty_buffer}

      {:ok, text, path} ->
        source = path || "Untitled buffer"
        {:ok, {:buffer, source, Path.basename(source), text}}

      {:error, :too_large} ->
        {:error, :source_too_large}
    end
  catch
    :exit, _reason -> {:error, :source_unavailable}
  end

  def capture_buffer(%State{}), do: {:error, :source_unavailable}

  @spec text(Document.t(), VisualState.selection_type(), Document.position()) ::
          {:ok, String.t()} | {:error, rejection()}
  defp text(document, :line, {line, _column}) do
    {cursor_line, _column} = Document.cursor(document)
    extract(document, Selection.linewise(document, line, cursor_line))
  end

  defp text(document, :char, anchor),
    do: extract(document, Selection.characterwise(document, anchor, Document.cursor(document)))

  @spec extract(Document.t(), Selection.t()) :: {:ok, String.t()} | {:error, rejection()}
  defp extract(_document, %Selection{span: %Span{start: byte, stop: byte}}),
    do: {:error, :no_selection}

  defp extract(_document, %Selection{span: %Span{start: first, stop: last}})
       when last - first > @max_bytes,
       do: {:error, :source_too_large}

  defp extract(document, selection),
    do: {:ok, :binary.copy(Selection.contents(document, selection))}
end
