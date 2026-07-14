defmodule MingaAgent.FileMention do
  @moduledoc """
  Handles `@file` mentions in chat input.

  Users type `@path/to/file.ex` in the chat input to attach file
  content as context to their prompt. This module extracts those
  references and resolves them to content blocks prepended to the
  prompt text.

  ## Mention format

  A mention is `@` followed by a file path. The `@` must appear at the
  start of the input or after whitespace (not mid-word). The path
  extends until the next whitespace or end of string.

  ## Resolution

  Each `@path` is:
  1. Resolved relative to the project root
  2. Read from disk
  3. Prepended to the prompt as a fenced code block with the file path

  If any mentioned file does not exist, resolution fails with an error
  message listing the missing files.
  """

  @typedoc "A single extracted mention: the file path and its grapheme-column range in the text."
  @type mention :: %{
          required(:path) => String.t(),
          required(:start_col) => non_neg_integer(),
          required(:end_col) => non_neg_integer(),
          optional(:start) => non_neg_integer(),
          optional(:stop) => non_neg_integer()
        }

  @typedoc "Completion state for the @-mention popup."
  @type completion :: %{
          prefix: String.t(),
          all_files: [String.t()],
          candidates: [String.t()],
          selected: non_neg_integer(),
          anchor_line: non_neg_integer(),
          anchor_col: non_neg_integer()
        }

  alias Minga.Project.Root
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.ModelLimits
  alias ReqLLM.Message.ContentPart

  @max_candidates 50
  @max_file_size 256 * 1024
  @max_image_size 5 * 1024 * 1024

  @image_extensions ~w(.png .jpg .jpeg .gif .webp)

  @image_media_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  # ── Extraction ──────────────────────────────────────────────────────────────

  @doc """
  Extracts `@path` mentions from prompt text.

  Returns a list of mention maps with the file path and its grapheme-column
  range. `start_col` and `end_col` are the explicit fields; `start` and `stop`
  are retained as compatibility aliases for existing callers.

  ## Examples

      iex> MingaAgent.FileMention.extract_mentions("@lib/foo.ex what does this do?")
      [%{path: "lib/foo.ex", start_col: 0, end_col: 11, start: 0, stop: 11}]

      iex> MingaAgent.FileMention.extract_mentions("look at @a.ex and @b.ex")
      [
        %{path: "a.ex", start_col: 8, end_col: 13, start: 8, stop: 13},
        %{path: "b.ex", start_col: 18, end_col: 23, start: 18, stop: 23}
      ]

      iex> MingaAgent.FileMention.extract_mentions("no mentions here")
      []

      iex> MingaAgent.FileMention.extract_mentions("email@example.com is not a mention")
      []

  """
  @spec extract_mentions(String.t()) :: [mention()]
  def extract_mentions(text) do
    # Match @ at start of string or after whitespace, followed by non-whitespace
    Regex.scan(~r/(?:^|(?<=\s))@(\S+)/, text, return: :index)
    |> Enum.map(fn [{_match_start, _match_len}, {path_start, path_len}] ->
      mention_start = path_start - 1
      mention_stop = path_start + path_len
      path = binary_part(text, path_start, path_len)

      start_col = byte_offset_to_col(text, mention_start)
      end_col = byte_offset_to_col(text, mention_stop)

      %{
        path: path,
        start: start_col,
        stop: end_col,
        start_col: start_col,
        end_col: end_col
      }
    end)
  end

  @doc "Returns the grapheme-column start for a mention, supporting legacy and explicit keys."
  @spec mention_start_col(mention()) :: non_neg_integer()
  def mention_start_col(%{start_col: start_col}), do: start_col
  def mention_start_col(%{start: start}), do: start

  @doc "Returns the grapheme-column end for a mention, supporting legacy and explicit keys."
  @spec mention_end_col(mention()) :: non_neg_integer()
  def mention_end_col(%{end_col: end_col}), do: end_col
  def mention_end_col(%{stop: stop}), do: stop

  @spec byte_offset_to_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_to_col(_text, 0), do: 0

  defp byte_offset_to_col(text, byte_offset) do
    text
    |> binary_part(0, byte_offset)
    |> String.length()
  end

  @doc """
  Resolves all `@path` mentions in the text and returns an augmented prompt.

  Each mentioned text file is prepended as a fenced code block.
  Image files (PNG, JPEG, GIF, WebP) are returned as ContentPart structs
  for multi-modal API requests.

  Returns:
  - `{:ok, String.t()}` when only text files are mentioned
  - `{:ok, [ContentPart.t()]}` when images are present (mixed text + image parts)
  - `{:error, message}` if any file doesn't exist or can't be read
  """
  @spec resolve_prompt(String.t(), Root.t() | nil) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  def resolve_prompt(text, workspace_root) do
    resolve_prompt(text, workspace_root, [])
  end

  @doc """
  Resolves mentions with options.

  Options:
    - `:model` — the model string for vision capability checking
  """
  @spec resolve_prompt(String.t(), Root.t() | nil, keyword()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  def resolve_prompt(text, nil, _opts) do
    case extract_mentions(text) do
      [] -> {:ok, text}
      _mentions -> {:error, "Cannot resolve file mentions without an active directory workspace"}
    end
  end

  def resolve_prompt(text, %Root{} = workspace_root, opts) do
    mentions = extract_mentions(text)

    if mentions == [] do
      {:ok, text}
    else
      maybe_check_vision(mentions, text, workspace_root, opts)
    end
  end

  @spec maybe_check_vision([mention()], String.t(), Root.t(), keyword()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  defp maybe_check_vision(mentions, text, workspace_root, opts) do
    has_images = Enum.any?(mentions, fn %{path: path} -> image_path?(path) end)
    model = Keyword.get(opts, :model)

    bare_model = if model, do: AgentConfig.strip_provider_prefix(model), else: nil

    if has_images and bare_model != nil and not ModelLimits.vision_capable?(bare_model) do
      {:error,
       "Model #{model} does not support image input. Use a vision-capable model (Claude, GPT-4o, Gemini)."}
    else
      resolve_all(mentions, text, workspace_root)
    end
  end

  @doc "Returns true if the path has an image file extension."
  @spec image_path?(String.t()) :: boolean()
  def image_path?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_extensions
  end

  @spec resolve_all([mention()], String.t(), Root.t()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  defp resolve_all(mentions, text, root) do
    results = Enum.map(mentions, &resolve_mention(&1, root))

    errors = Enum.filter(results, fn {_path, result} -> match?({:error, _}, result) end)

    if errors != [] do
      missing = Enum.map(errors, fn {path, {:error, reason}} -> "  #{path}: #{reason}" end)
      {:error, "Cannot resolve file mentions:\n#{Enum.join(missing, "\n")}"}
    else
      has_images =
        Enum.any?(results, fn {_path, result} -> match?({:ok, {:image, _, _, _}}, result) end)

      body = remove_mentions(text, mentions)

      if has_images do
        build_multimodal_parts(results, body)
      else
        build_text_prompt(results, body)
      end
    end
  end

  @spec resolve_mention(mention(), Root.t()) ::
          {String.t(),
           {:ok, String.t()}
           | {:ok, {:image, binary(), String.t(), non_neg_integer()}}
           | {:error, String.t()}}
  defp resolve_mention(%{path: path}, root) do
    case Root.resolve_file(root, path) do
      {:ok, abs_path} -> {path, read_mention(path, abs_path)}
      {:error, reason} -> {path, {:error, resolution_error(reason)}}
    end
  end

  @spec read_mention(String.t(), String.t()) ::
          {:ok, String.t()}
          | {:ok, {:image, binary(), String.t(), non_neg_integer()}}
          | {:error, String.t()}
  defp read_mention(path, abs_path) do
    if image_path?(path), do: read_image_safe(abs_path), else: read_file_safe(abs_path)
  end

  @spec resolution_error(Root.file_error()) :: String.t()
  defp resolution_error(:absolute_path),
    do: "absolute paths are outside the active workspace"

  defp resolution_error(:parent_traversal),
    do: "path is outside the active workspace (parent traversal is not allowed)"

  defp resolution_error(:outside_workspace),
    do: "path is outside the active workspace"

  defp resolution_error(:enoent), do: "file not found"

  defp resolution_error(:not_a_directory_root),
    do: "active workspace root is not an authorized directory"

  defp resolution_error(:broad_root_confirmation_required),
    do: "active workspace root requires broad-root confirmation"

  defp resolution_error(:invalid_broad_root_confirmation),
    do: "active workspace root has invalid broad-root confirmation"

  defp resolution_error(:root_changed),
    do: "active workspace root changed after authorization"

  defp resolution_error(reason), do: "cannot resolve path (#{reason})"

  @spec build_text_prompt([{String.t(), {:ok, String.t()}}], String.t()) :: {:ok, String.t()}
  defp build_text_prompt(results, body) do
    context_blocks =
      Enum.map_join(results, "\n\n", fn {path, {:ok, content}} ->
        ext = Path.extname(path) |> String.trim_leading(".")
        "Contents of #{path}:\n```#{ext}\n#{content}\n```"
      end)

    prompt = context_blocks <> "\n\n" <> String.trim(body)
    {:ok, prompt}
  end

  @spec build_multimodal_parts(
          [
            {String.t(),
             {:ok, String.t()} | {:ok, {:image, binary(), String.t(), non_neg_integer()}}}
          ],
          String.t()
        ) :: {:ok, [ContentPart.t()]}
  defp build_multimodal_parts(results, body) do
    # Build text context for non-image files
    text_parts =
      results
      |> Enum.reject(fn {_path, result} -> match?({:ok, {:image, _, _, _}}, result) end)
      |> Enum.map(fn {path, {:ok, content}} ->
        ext = Path.extname(path) |> String.trim_leading(".")
        "Contents of #{path}:\n```#{ext}\n#{content}\n```"
      end)

    # Build image parts
    image_parts =
      results
      |> Enum.filter(fn {_path, result} -> match?({:ok, {:image, _, _, _}}, result) end)
      |> Enum.map(fn {path, {:ok, {:image, data, media_type, size}}} ->
        size_kb = div(size, 1024)
        metadata = %{filename: Path.basename(path), size_display: "#{size_kb}KB"}
        ContentPart.image(data, media_type, metadata)
      end)

    # Combine: text context first, then the user's prompt, then images
    text_context = Enum.join(text_parts, "\n\n")

    prompt_text =
      if text_context == "" do
        String.trim(body)
      else
        text_context <> "\n\n" <> String.trim(body)
      end

    parts = [ContentPart.text(prompt_text) | image_parts]
    {:ok, parts}
  end

  @spec read_image_safe(String.t()) ::
          {:ok, {:image, binary(), String.t(), non_neg_integer()}} | {:error, String.t()}
  defp read_image_safe(path) do
    ext = path |> Path.extname() |> String.downcase()
    media_type = Map.get(@image_media_types, ext, "image/png")

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_image_size ->
        {:error, "image too large (#{div(size, 1024)}KB, max #{div(@max_image_size, 1024)}KB)"}

      {:ok, %{type: :regular, size: size}} ->
        case File.read(path) do
          {:ok, data} -> {:ok, {:image, data, media_type, size}}
          {:error, reason} -> {:error, "#{reason}"}
        end

      {:ok, %{type: type}} ->
        {:error, "not a regular file (#{type})"}

      {:error, :enoent} ->
        {:error, "file not found"}

      {:error, reason} ->
        {:error, "#{reason}"}
    end
  end

  @spec read_file_safe(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_file_safe(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_file_size ->
        {:error, "file too large (#{div(size, 1024)}KB, max #{div(@max_file_size, 1024)}KB)"}

      {:ok, %{type: :regular}} ->
        read_text_file(path)

      {:ok, %{type: type}} ->
        {:error, "not a regular file (#{type})"}

      {:error, :enoent} ->
        {:error, "file not found"}

      {:error, reason} ->
        {:error, "#{reason}"}
    end
  end

  @spec read_text_file(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp read_text_file(path) do
    case File.read(path) do
      {:ok, content} when is_binary(content) ->
        validate_text_content(content)

      {:error, reason} ->
        {:error, "#{reason}"}
    end
  end

  @spec validate_text_content(binary()) :: {:ok, String.t()} | {:error, String.t()}
  defp validate_text_content(content) do
    if String.valid?(content) do
      {:ok, content}
    else
      {:error, "binary file, not text"}
    end
  end

  @spec remove_mentions(String.t(), [mention()]) :: String.t()
  defp remove_mentions(text, mentions) do
    # Remove mentions in reverse order so positions stay valid
    mentions
    |> Enum.sort_by(&mention_start_col/1, :desc)
    |> Enum.reduce(text, fn mention, acc ->
      before = String.slice(acc, 0, mention_start_col(mention))
      # Skip any trailing space after the mention
      after_mention = String.slice(acc, mention_end_col(mention), String.length(acc))
      after_trimmed = String.trim_leading(after_mention, " ")
      before <> after_trimmed
    end)
  end

  # ── Completion ──────────────────────────────────────────────────────────────

  @doc """
  Creates a new completion state from the current file list.

  `anchor_line` and `anchor_col` mark where the `@` was typed so the
  completion popup knows where to render and where to insert the result.
  """
  @spec new_completion([String.t()], non_neg_integer(), non_neg_integer()) :: completion()
  def new_completion(all_files, anchor_line, anchor_col) do
    candidates = Enum.take(all_files, @max_candidates)

    %{
      prefix: "",
      all_files: all_files,
      candidates: candidates,
      selected: 0,
      anchor_line: anchor_line,
      anchor_col: anchor_col
    }
  end

  @doc "Updates the prefix and re-filters candidates."
  @spec update_prefix(completion(), String.t()) :: completion()
  def update_prefix(completion, new_prefix) do
    filtered = filter_files(completion.all_files, new_prefix)
    candidates = Enum.take(filtered, @max_candidates)
    selected = min(completion.selected, max(Enum.count(candidates) - 1, 0))

    %{completion | prefix: new_prefix, candidates: candidates, selected: selected}
  end

  @doc "Moves selection down (wraps around)."
  @spec select_next(completion()) :: completion()
  def select_next(%{candidates: []} = c), do: c

  def select_next(%{candidates: candidates, selected: sel} = c) do
    %{c | selected: rem(sel + 1, Enum.count(candidates))}
  end

  @doc "Moves selection up (wraps around)."
  @spec select_prev(completion()) :: completion()
  def select_prev(%{candidates: []} = c), do: c

  def select_prev(%{candidates: candidates, selected: sel} = c) do
    total = Enum.count(candidates)
    %{c | selected: rem(sel - 1 + total, total)}
  end

  @doc "Returns the currently selected candidate path, or nil if none."
  @spec selected_path(completion()) :: String.t() | nil
  def selected_path(%{candidates: [], selected: _}), do: nil
  def selected_path(%{candidates: candidates, selected: sel}), do: Enum.at(candidates, sel)

  @spec filter_files([String.t()], String.t()) :: [String.t()]
  defp filter_files(files, "") do
    files
  end

  defp filter_files(files, prefix) do
    lower = String.downcase(prefix)

    files
    |> Enum.flat_map(&candidate_rank(&1, lower))
    |> Enum.sort_by(fn {rank, path} -> {rank, path} end)
    |> Enum.map(fn {_rank, path} -> path end)
  end

  @spec candidate_rank(String.t(), String.t()) :: [{non_neg_integer(), String.t()}]
  defp candidate_rank(path, lower_prefix) do
    lower_path = String.downcase(path)
    basename = Path.basename(lower_path)

    case path_rank(lower_path, basename, lower_prefix) do
      nil -> []
      rank -> [{rank, path}]
    end
  end

  @spec path_rank(String.t(), String.t(), String.t()) :: non_neg_integer() | nil
  defp path_rank(lower_path, _basename, lower_prefix)
       when lower_path == lower_prefix,
       do: 0

  defp path_rank(_lower_path, basename, lower_prefix)
       when basename == lower_prefix,
       do: 1

  defp path_rank(lower_path, _basename, lower_prefix) do
    path_rank_by_match(lower_path, lower_prefix)
  end

  @spec path_rank_by_match(String.t(), String.t()) :: non_neg_integer() | nil
  defp path_rank_by_match(lower_path, lower_prefix) do
    basename = Path.basename(lower_path)

    case {String.starts_with?(lower_path, lower_prefix),
          String.starts_with?(basename, lower_prefix), String.contains?(lower_path, lower_prefix),
          subsequence?(lower_prefix, lower_path)} do
      {true, _, _, _} -> 2
      {_, true, _, _} -> 3
      {_, _, true, _} -> 4
      {_, _, _, true} -> 5
      _ -> nil
    end
  end

  @spec subsequence?(String.t(), String.t()) :: boolean()
  defp subsequence?("", _text), do: true
  defp subsequence?(_needle, ""), do: false

  defp subsequence?(needle, text) do
    needle
    |> String.graphemes()
    |> do_subsequence?(String.graphemes(text))
  end

  @spec do_subsequence?([String.t()], [String.t()]) :: boolean()
  defp do_subsequence?([], _text), do: true
  defp do_subsequence?(_needle, []), do: false

  defp do_subsequence?([char | needle], [char | text]), do: do_subsequence?(needle, text)
  defp do_subsequence?(needle, [_char | text]), do: do_subsequence?(needle, text)
end
