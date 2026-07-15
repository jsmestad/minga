defmodule MingaEditor.UI.Picker.TodoSearchSource do
  @moduledoc """
  Picker source for project TODO-style comment markers.

  Uses `git grep` in repositories so ignored files stay ignored, and falls back to recursive `grep` outside git repositories.

  The scan is async: the picker opens immediately with a "Searching…" indicator
  and the project-wide `git grep`/`grep` effect runs through the generation-owned
  scheduler off the editor input path, with latest-wins stale-result protection
  (a reopen or project switch drops an older in-flight result).
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Language
  alias Minga.Language.Devicon
  alias Minga.Project.Root
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @max_results 1_000

  @type marker :: %{
          path: String.t(),
          line: pos_integer(),
          text: String.t()
        }
  @type output_format :: :git | :grep

  @impl true
  @spec title() :: String.t()
  def title, do: "Search TODOs"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context), do: []

  @doc "Maximum number of parsed TODO matches returned by one search."
  @spec max_results() :: pos_integer()
  def max_results, do: @max_results

  @doc "Parses NUL-framed grep output and reports whether matches were truncated."
  @spec parse_output(String.t(), output_format()) :: {[marker()], boolean()}
  def parse_output(output, format) when is_binary(output) and format in [:git, :grep] do
    markers = parse_records(output, format, @max_results + 1, [])
    truncated? = length(markers) > @max_results
    {Enum.take(markers, @max_results), truncated?}
  end

  @doc "Builds picker items only for candidates authorized by the captured workspace Root."
  @spec build_candidates([marker()], Root.t()) :: [Item.t()]
  def build_candidates(markers, %Root{} = root) when is_list(markers) do
    markers
    |> Enum.with_index()
    |> Enum.flat_map(fn {marker, idx} -> marker_item(marker, idx, root) end)
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

  @spec parse_records(binary(), output_format(), non_neg_integer(), [marker()]) :: [marker()]
  defp parse_records(_output, _format, 0, acc), do: Enum.reverse(acc)
  defp parse_records("", _format, _remaining, acc), do: Enum.reverse(acc)

  defp parse_records(output, :git, remaining, acc) do
    with {:ok, path, after_path} <- split_once(output, <<0>>),
         {:ok, line_number, after_line} <- split_once(after_path, <<0>>),
         {:ok, text, rest} <- take_record_line(after_line) do
      parse_records(rest, :git, remaining - 1, add_match(acc, path, line_number, text))
    else
      :error -> Enum.reverse(acc)
    end
  end

  defp parse_records(output, :grep, remaining, acc) do
    with {:ok, path, after_path} <- split_once(output, <<0>>),
         {:ok, record, rest} <- take_record_line(after_path),
         [line_number, text] <- String.split(record, ":", parts: 2) do
      parse_records(rest, :grep, remaining - 1, add_match(acc, path, line_number, text))
    else
      _ -> Enum.reverse(acc)
    end
  end

  @spec add_match([marker()], String.t(), String.t(), String.t()) :: [marker()]
  defp add_match(acc, path, line_number, text) do
    case Integer.parse(line_number) do
      {line, ""} when line > 0 -> [%{path: path, line: line, text: text} | acc]
      _ -> acc
    end
  end

  @spec split_once(binary(), binary()) :: {:ok, binary(), binary()} | :error
  defp split_once(binary, delimiter) do
    case :binary.match(binary, delimiter) do
      {offset, length} ->
        before = binary_part(binary, 0, offset)
        rest_offset = offset + length
        rest = binary_part(binary, rest_offset, byte_size(binary) - rest_offset)
        {:ok, before, rest}

      :nomatch ->
        :error
    end
  end

  @spec take_record_line(binary()) :: {:ok, binary(), binary()} | :error
  defp take_record_line(""), do: :error

  defp take_record_line(binary) do
    case split_once(binary, "\n") do
      {:ok, line, rest} -> {:ok, line, rest}
      :error -> {:ok, binary, ""}
    end
  end

  @spec marker_item(marker(), non_neg_integer(), Root.t()) :: [Item.t()]
  defp marker_item(marker, idx, %Root{} = root) do
    relative_path = candidate_relative_path(marker.path, root.path)

    case Root.resolve_file(root, relative_path) do
      {:ok, path} -> [authorized_item(marker, idx, path, root.path)]
      {:error, _reason} -> []
    end
  end

  @spec candidate_relative_path(String.t(), String.t()) :: String.t()
  defp candidate_relative_path(path, canonical_root) do
    case Path.type(path) do
      :absolute -> Path.relative_to(path, canonical_root)
      :relative -> path
      :volumerelative -> path
    end
  end

  @spec authorized_item(marker(), non_neg_integer(), String.t(), String.t()) :: Item.t()
  defp authorized_item(marker, idx, path, canonical_root) do
    rel_path = Path.relative_to(path, canonical_root)
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
    case MingaEditor.Handlers.BufferRegistry.find_buffer_by_path(state, abs_path) do
      nil -> open_new_buffer(state, abs_path, line, col)
      buf_idx -> jump_to_buffer(state, buf_idx, line, col)
    end
  end

  @spec open_new_buffer(term(), String.t(), non_neg_integer(), non_neg_integer()) :: term()
  defp open_new_buffer(state, abs_path, line, col) do
    case MingaEditor.Commands.start_buffer(abs_path) do
      {:ok, pid} ->
        new_state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, pid)
        Buffer.move_to(pid, {line, col})
        new_state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end

  @spec jump_to_buffer(term(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: term()
  defp jump_to_buffer(state, buf_idx, line, col) do
    new_state = MingaEditor.BufferActivation.activate(state, buf_idx)
    pid = Enum.at(state.workspace.buffers.list, buf_idx)
    Buffer.move_to(pid, {line, col})
    new_state
  end
end
