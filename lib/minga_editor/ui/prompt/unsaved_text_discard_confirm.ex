defmodule MingaEditor.UI.Prompt.UnsavedTextDiscardConfirm do
  @moduledoc """
  Prompt handler that confirms deleting unsaved text that is waiting in a swap file.

  The swap file is the only copy of that text, so the prompt names the file, says how much text goes, and says that it cannot be undone. Only `y` or `yes` deletes.
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias Minga.Session
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @max_name_graphemes 60
  # The frontends take a prompt label of at most this many bytes.
  @max_prompt_bytes 255
  @ellipsis "…"

  @impl true
  @spec label() :: String.t()
  def label, do: "Delete this unsaved text? It cannot be undone. (y/n): "

  @doc "The prompt for one waiting entry: its file name and how many lines are deleted."
  @spec label(Session.waiting_unsaved_text()) :: String.t()
  def label(%{path: path, lines: lines}) do
    prefix = "Delete the unsaved text of "
    suffix = " (#{line_count(lines)})? It cannot be undone. (y/n): "
    name_bytes = @max_prompt_bytes - byte_size(prefix) - byte_size(suffix)

    prefix <> fit(Path.basename(path), name_bytes) <> suffix
  end

  @impl true
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state), do: confirm(text, state, target(nil, state))

  @impl true
  @spec on_submit(String.t(), EditorState.t(), map() | nil) :: EditorState.t()
  def on_submit(text, state, context), do: confirm(text, state, target(context, state))

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: NoticeWorkflow.publish(state, "Kept the unsaved text")

  @spec confirm(String.t(), EditorState.t(), {String.t(), String.t()} | nil) :: EditorState.t()
  defp confirm(_text, state, nil), do: NoticeWorkflow.publish(state, "No unsaved text selected")

  defp confirm(text, state, {path, swap_path}) do
    if String.downcase(String.trim(text)) in ["y", "yes"] do
      :ok = Session.discard_swap_file(swap_path)
      Minga.Log.info(:editor, "Deleted the unsaved text of #{path} (#{swap_path})")
      NoticeWorkflow.publish(state, "Deleted the unsaved text of #{name(path)}")
    else
      NoticeWorkflow.publish(state, "Kept the unsaved text of #{name(path)}")
    end
  end

  @spec target(map() | nil, EditorState.t()) :: {String.t(), String.t()} | nil
  defp target(%{path: path, swap_path: swap_path}, _state)
       when is_binary(path) and is_binary(swap_path),
       do: {path, swap_path}

  defp target(_context, %{
         shell_runtime: %{
           state: %{
             modal: {:prompt, %{prompt_ui: %{context: %{path: path, swap_path: swap_path}}}}
           }
         }
       })
       when is_binary(path) and is_binary(swap_path),
       do: {path, swap_path}

  defp target(_context, _state), do: nil

  @spec name(String.t()) :: String.t()
  defp name(path) do
    base = Path.basename(path)

    if String.length(base) > @max_name_graphemes,
      do: String.slice(base, 0, @max_name_graphemes) <> @ellipsis,
      else: base
  end

  # Shortens a name to a byte budget without cutting a grapheme in half.
  @spec fit(String.t(), pos_integer()) :: String.t()
  defp fit(name, max_bytes) when byte_size(name) <= max_bytes, do: name

  defp fit(name, max_bytes) do
    budget = max_bytes - byte_size(@ellipsis)

    {kept, _used} =
      name
      |> String.graphemes()
      |> Enum.reduce_while({"", 0}, fn grapheme, {kept, used} ->
        used = used + byte_size(grapheme)
        if used <= budget, do: {:cont, {kept <> grapheme, used}}, else: {:halt, {kept, used}}
      end)

    kept <> @ellipsis
  end

  @spec line_count(non_neg_integer()) :: String.t()
  defp line_count(1), do: "1 line"
  defp line_count(count), do: "#{count} lines"
end
