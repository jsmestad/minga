defmodule Minga.Agent.FileMention do
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

  @typedoc "A single extracted mention: the file path and its character range in the text."
  @type mention :: %{
          path: String.t(),
          start: non_neg_integer(),
          stop: non_neg_integer()
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

  alias Minga.Agent.ModelLimits
  alias ReqLLM.Message.ContentPart

  @max_candidates 10
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

  Returns a list of mention maps with the file path and its character
  position range (for potential highlighting or removal).

  ## Examples

      iex> Minga.Agent.FileMention.extract_mentions("@lib/foo.ex what does this do?")
      [%{path: "lib/foo.ex", start: 0, stop: 14}]

      iex> Minga.Agent.FileMention.extract_mentions("look at @a.ex and @b.ex")
      [%{path: "a.ex", start: 8, stop: 14}, %{path: "b.ex", start: 19, stop: 24}]

      iex> Minga.Agent.FileMention.extract_mentions("no mentions here")
      []

      iex> Minga.Agent.FileMention.extract_mentions("email@example.com is not a mention")
      []

  """
  @spec extract_mentions(String.t()) :: [mention()]
  def extract_mentions(text) do
    # Match @ at start of string or after whitespace, followed by non-whitespace
    Regex.scan(~r/(?:^|(?<=\s))@(\S+)/, text, return: :index)
    |> Enum.map(fn [{start, len}, {_path_start, path_len}] ->
      # The full match includes the @, but path is the capture group
      path = String.slice(text, start + 1, path_len)
      %{path: path, start: start, stop: start + len}
    end)
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
  @spec resolve_prompt(String.t(), String.t()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  def resolve_prompt(text, project_root) do
    resolve_prompt(text, project_root, [])
  end

  @doc """
  Resolves mentions with options.

  Options:
    - `:model` — the model string for vision capability checking
  """
  @spec resolve_prompt(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  def resolve_prompt(text, project_root, opts) do
    mentions = extract_mentions(text)

    if mentions == [] do
      {:ok, text}
    else
      maybe_check_vision(mentions, text, project_root, opts)
    end
  end

  @spec maybe_check_vision([mention()], String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  defp maybe_check_vision(mentions, text, project_root, opts) do
    has_images = Enum.any?(mentions, fn %{path: path} -> image_path?(path) end)
    model = Keyword.get(opts, :model)

    if has_images and model != nil and not ModelLimits.vision_capable?(model) do
      {:error,
       "Model #{model} does not support image input. Use a vision-capable model (Claude, GPT-4o, Gemini)."}
    else
      resolve_all(mentions, text, project_root)
    end
  end

  @doc "Returns true if the path has an image file extension."
  @spec image_path?(String.t()) :: boolean()
  def image_path?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @image_extensions
  end

  @spec resolve_all([mention()], String.t(), String.t()) ::
          {:ok, String.t()} | {:ok, [ContentPart.t()]} | {:error, String.t()}
  defp resolve_all(mentions, text, root) do
    results =
      Enum.map(mentions, fn %{path: path} ->
        abs_path = Path.expand(path, root)

        if image_path?(path) do
          {path, read_image_safe(abs_path)}
        else
          {path, read_file_safe(abs_path)}
        end
      end)

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
    |> Enum.sort_by(& &1.start, :desc)
    |> Enum.reduce(text, fn %{start: s, stop: e}, acc ->
      before = String.slice(acc, 0, s)
      # Skip any trailing space after the mention
      after_mention = String.slice(acc, e, String.length(acc))
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
    selected = min(completion.selected, max(length(candidates) - 1, 0))

    %{completion | prefix: new_prefix, candidates: candidates, selected: selected}
  end

  @doc "Moves selection down (wraps around)."
  @spec select_next(completion()) :: completion()
  def select_next(%{candidates: []} = c), do: c

  def select_next(%{candidates: candidates, selected: sel} = c) do
    %{c | selected: rem(sel + 1, length(candidates))}
  end

  @doc "Moves selection up (wraps around)."
  @spec select_prev(completion()) :: completion()
  def select_prev(%{candidates: []} = c), do: c

  def select_prev(%{candidates: candidates, selected: sel} = c) do
    total = length(candidates)
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
    |> Enum.filter(fn path ->
      String.contains?(String.downcase(path), lower)
    end)
    |> Enum.sort_by(fn path ->
      # Prefer prefix matches over substring matches
      lower_path = String.downcase(path)

      cond do
        String.starts_with?(lower_path, lower) -> {0, path}
        String.starts_with?(Path.basename(String.downcase(path)), lower) -> {1, path}
        true -> {2, path}
      end
    end)
  end
end
