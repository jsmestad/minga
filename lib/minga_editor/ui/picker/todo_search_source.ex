defmodule MingaEditor.UI.Picker.TodoSearchSource do
  @moduledoc """
  Picker source for project TODO-style comment markers.

  Uses `git grep` in repositories so ignored files stay ignored, and falls back to recursive `grep` outside git repositories.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Language
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Devicon
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @keyword_pattern "(^|[[:space:]])(#|//|/\\*|%|--)[[:space:]]*(TODO|FIXME|HACK|NOTE|REVIEW|DEPRECATED)([^[:alnum:]_]|$)"

  @type marker :: %{
          path: String.t(),
          line: pos_integer(),
          text: String.t()
        }

  @impl true
  @spec title() :: String.t()
  def title, do: "Search TODOs"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context) do
    root = Minga.Project.resolve_root()

    root
    |> search_output()
    |> build_candidates(root)
  end

  @doc "Parses grep-style `path:line:text` output into marker maps."
  @spec parse_output(String.t()) :: [marker()]
  def parse_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
  end

  @doc "Builds picker items from parsed marker maps."
  @spec build_candidates([marker()] | {:ok, String.t()} | {:error, String.t()}, String.t()) :: [
          Item.t()
        ]
  def build_candidates({:ok, output}, root),
    do: output |> parse_output() |> build_candidates(root)

  def build_candidates({:error, _message}, _root), do: []

  def build_candidates(markers, root) when is_list(markers) do
    markers
    |> Enum.with_index()
    |> Enum.map(fn {marker, idx} -> marker_item(marker, idx, root) end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: %{path: path, line: line}}, state) do
    open_match(state, path, max(line - 1, 0), 0)
  end

  def on_select(_item, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: Source.restore_or_keep(state)

  @spec search_output(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp search_output(root) do
    if git_repo?(root) do
      run_git_grep(root)
    else
      run_grep(root)
    end
  end

  @spec git_repo?(String.t()) :: boolean()
  defp git_repo?(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--is-inside-work-tree"],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  @spec run_git_grep(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_git_grep(root) do
    run_search_command("git", ["-C", root, "grep", "-n", "-I", "-E", @keyword_pattern, "--", "."])
  end

  @spec run_grep(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_grep(root) do
    run_search_command("grep", ["-rnEI", "--exclude-dir=.git", @keyword_pattern, root])
  end

  @spec run_search_command(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp run_search_command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, 1} -> {:ok, ""}
      {output, _status} -> {:error, output}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @spec parse_line(String.t()) :: [marker()]
  defp parse_line(line) do
    case String.split(line, ":", parts: 3) do
      [path, line_number, text] -> parse_match(path, line_number, text)
      _ -> []
    end
  end

  @spec parse_match(String.t(), String.t(), String.t()) :: [marker()]
  defp parse_match(path, line_number, text) do
    case Integer.parse(line_number) do
      {line, ""} when line > 0 -> [%{path: path, line: line, text: text}]
      _ -> []
    end
  end

  @spec marker_item(marker(), non_neg_integer(), String.t()) :: Item.t()
  defp marker_item(marker, idx, root) do
    path = Path.expand(marker.path, root)
    rel_path = Path.relative_to(path, root)
    filename = Path.basename(path)
    filetype = Language.detect_filetype(filename)
    {icon, color} = Devicon.icon_and_color(filetype)

    %Item{
      id: %{path: path, line: marker.line, index: idx},
      label: "#{icon} #{rel_path}:#{marker.line}",
      description: String.trim(marker.text),
      icon_color: color,
      two_line: true
    }
  end

  @spec open_match(term(), String.t(), non_neg_integer(), non_neg_integer()) :: term()
  defp open_match(state, abs_path, line, col) do
    case EditorState.find_buffer_by_path(state, abs_path) do
      nil -> open_new_buffer(state, abs_path, line, col)
      buf_idx -> jump_to_buffer(state, buf_idx, line, col)
    end
  end

  @spec open_new_buffer(term(), String.t(), non_neg_integer(), non_neg_integer()) :: term()
  defp open_new_buffer(state, abs_path, line, col) do
    case EditorState.start_buffer(abs_path) do
      {:ok, pid} ->
        new_state = EditorState.add_buffer(state, pid)
        Buffer.move_to(pid, {line, col})
        new_state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @spec jump_to_buffer(term(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: term()
  defp jump_to_buffer(state, buf_idx, line, col) do
    new_state = EditorState.switch_buffer(state, buf_idx)
    pid = Enum.at(state.workspace.buffers.list, buf_idx)
    Buffer.move_to(pid, {line, col})
    new_state
  end
end
