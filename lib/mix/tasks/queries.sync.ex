defmodule Mix.Tasks.Queries.Sync do
  @moduledoc """
  Sync highlight queries from nvim-treesitter.

  Clones (or reuses) nvim-treesitter, copies `highlights.scm` for all 42
  languages Minga ships, and applies these transformations:

  1. `#lua-match?` → `#match?` with Lua pattern → regex conversion
  2. Strips `@spell`, `@nospell`, `@conceal`, `@none` captures
  3. Strips `#set! conceal`, `#set! priority`, `#set! conceal_lines` directives
     (moves trailing closing parens to the previous line to keep S-expressions valid)
  4. Strips `#set! ... url ...` directives
  5. Cleans up empty patterns and excess blank lines

  Records the source commit in `priv/queries/VERSION`.

  ## Usage

      mix queries.sync                          # clones to /tmp/nvim-treesitter
      mix queries.sync /path/to/nvim-treesitter # reuses existing clone
  """

  use Mix.Task

  @shortdoc "Sync highlight queries from nvim-treesitter"

  @languages ~w(
    bash c c_sharp cpp css dart diff dockerfile ecma elixir erlang gleam go
    graphql haskell hcl html html_tags java javascript json jsx kotlin lua
    make markdown markdown_inline nix ocaml php php_only python r ruby rust
    scala scss toml tsx typescript yaml zig
  )

  @skip_languages ~w(elisp)

  @lua_replacements [
    {"%d", "[0-9]"},
    {"%l", "[a-z]"},
    {"%u", "[A-Z]"},
    {"%a", "[a-zA-Z]"},
    {"%w", "[a-zA-Z0-9]"},
    {"%s", "[ \\t]"}
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    nvim_ts_dir = resolve_source(args)
    nvim_queries = Path.join([nvim_ts_dir, "runtime", "queries"])
    target_dir = Path.join(Mix.Project.project_file() |> Path.dirname(), "priv/queries")

    source_commit = get_commit(nvim_ts_dir)
    Mix.shell().info("Source: nvim-treesitter @ #{source_commit}")
    Mix.shell().info("Target: #{target_dir}\n")

    {synced, skipped} =
      Enum.reduce(@languages, {0, 0}, fn lang, {s, sk} ->
        cond do
          lang in @skip_languages ->
            Mix.shell().info([:yellow, "SKIP (not in nvim-ts): #{lang}", :reset])
            {s, sk + 1}

          not File.exists?(Path.join([nvim_queries, lang, "highlights.scm"])) ->
            Mix.shell().info([:yellow, "SKIP (not found): #{lang}", :reset])
            {s, sk + 1}

          true ->
            src = Path.join([nvim_queries, lang, "highlights.scm"])
            dst = Path.join([target_dir, lang, "highlights.scm"])
            content = File.read!(src)
            transformed = transform_query(content)
            File.write!(dst, transformed)
            Mix.shell().info([:green, "SYNCED: #{lang}", :reset])
            {s + 1, sk}
        end
      end)

    write_version(target_dir, source_commit)
    Mix.shell().info("\nDone: #{synced} synced, #{skipped} skipped")
  end

  @spec resolve_source([String.t()]) :: String.t()
  defp resolve_source([dir | _]) when is_binary(dir) do
    unless File.dir?(dir) do
      Mix.raise("Directory not found: #{dir}")
    end

    dir
  end

  defp resolve_source(_args) do
    dir = "/tmp/nvim-treesitter"

    if File.dir?(dir) do
      Mix.shell().info("Reusing existing clone at #{dir}")
    else
      Mix.shell().info("Cloning nvim-treesitter to #{dir}...")

      {_, 0} =
        System.cmd("git", [
          "clone",
          "--depth",
          "1",
          "https://github.com/nvim-treesitter/nvim-treesitter.git",
          dir
        ])
    end

    dir
  end

  @spec get_commit(String.t()) :: String.t()
  defp get_commit(dir) do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    String.trim(commit)
  end

  @spec transform_query(String.t()) :: String.t()
  defp transform_query(content) do
    content
    |> remove_conceal_only_blocks()
    |> String.split("\n")
    |> process_lines([])
    |> Enum.reverse()
    |> collapse_blank_lines()
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # Remove entire top-level S-expression blocks where @conceal is the only
  # meaningful capture. These patterns exist solely for nvim's conceal feature
  # and become broken (or no-ops) when @conceal is stripped. Example:
  #
  #   ("\"" @conceal
  #     (#set! conceal ""))
  #
  # We split the file into blocks (separated by blank lines), check each
  # block, and drop the conceal-only ones before line-level processing.
  @spec remove_conceal_only_blocks(String.t()) :: String.t()
  defp remove_conceal_only_blocks(content) do
    lines = String.split(content, "\n")
    {blocks, current} = chunk_into_blocks(lines, [], [])
    blocks = if current != [], do: blocks ++ [Enum.reverse(current)], else: blocks

    blocks
    |> Enum.reject(&conceal_only_block?/1)
    |> Enum.intersperse([""])
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec chunk_into_blocks([String.t()], [[String.t()]], [String.t()]) ::
          {[[String.t()]], [String.t()]}
  defp chunk_into_blocks([], blocks, current), do: {blocks, current}

  defp chunk_into_blocks([line | rest], blocks, current) do
    if String.trim(line) == "" and current != [] do
      chunk_into_blocks(rest, blocks ++ [Enum.reverse(current)], [])
    else
      chunk_into_blocks(rest, blocks, [line | current])
    end
  end

  # A block is conceal-only if it contains @conceal as a capture AND
  # #set! conceal, AND no other meaningful captures (non-@conceal, non-nvim).
  @spec conceal_only_block?([String.t()]) :: boolean()
  defp conceal_only_block?(block) do
    text = Enum.join(block, "\n")
    has_conceal_capture = String.contains?(text, "@conceal")
    has_set_conceal = Regex.match?(~r/#set!\s+conceal/, text)

    if has_conceal_capture and has_set_conceal do
      captures =
        Regex.scan(~r/@(\w[\w.]*)/, text)
        |> Enum.map(fn [_, name] -> name end)
        |> Enum.reject(fn name ->
          name in ~w(conceal spell nospell none) or String.starts_with?(name, "_")
        end)

      captures == []
    else
      false
    end
  end

  @spec process_lines([String.t()], [String.t()]) :: [String.t()]
  defp process_lines([], acc), do: acc

  defp process_lines([line | rest], acc) do
    line = convert_lua_match(line)
    line = strip_nvim_captures(line)

    if removable_set_directive?(String.trim(line)) do
      acc = transfer_trailing_parens(line, acc)
      process_lines(rest, acc)
    else
      process_lines(rest, [line | acc])
    end
  end

  @spec convert_lua_match(String.t()) :: String.t()
  defp convert_lua_match(line) do
    if String.contains?(line, "lua-match?") do
      line
      |> String.replace("#not-lua-match?", "#not-match?")
      |> String.replace("#lua-match?", "#match?")
      |> lua_to_regex()
    else
      line
    end
  end

  @spec lua_to_regex(String.t()) :: String.t()
  defp lua_to_regex(line) do
    Enum.reduce(@lua_replacements, line, fn {lua, regex}, acc ->
      String.replace(acc, lua, regex)
    end)
  end

  @spec strip_nvim_captures(String.t()) :: String.t()
  defp strip_nvim_captures(line) do
    Regex.replace(~r/\s+@(?:spell|nospell|conceal|none)\b/, line, "")
  end

  @spec removable_set_directive?(String.t()) :: boolean()
  defp removable_set_directive?(trimmed) do
    Regex.match?(~r/^\(#set!\s+(?:conceal|conceal_lines|priority)\b/, trimmed) or
      Regex.match?(~r/^\(#set!\s+@\w+\s+url\b/, trimmed)
  end

  # When we remove a #set! line, its trailing `)` chars may include parens
  # that close outer S-expressions. The #set! itself owns one `(` (the opening
  # of `(#set! ...)`), so one `)` is its own. Any extra `)` must be appended
  # to the previous non-blank line to keep the tree balanced.
  @spec transfer_trailing_parens(String.t(), [String.t()]) :: [String.t()]
  defp transfer_trailing_parens(line, acc) do
    trimmed = String.trim(line)
    trailing = count_trailing_parens(trimmed)
    # The #set! directive's own opening paren needs one closing paren
    extra = max(trailing - 1, 0)

    if extra > 0 do
      append_parens_to_previous(acc, extra)
    else
      acc
    end
  end

  @spec count_trailing_parens(String.t()) :: non_neg_integer()
  defp count_trailing_parens(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.take_while(&(&1 == ")"))
    |> length()
  end

  @spec append_parens_to_previous([String.t()], non_neg_integer()) :: [String.t()]
  defp append_parens_to_previous([], _extra), do: []

  defp append_parens_to_previous([prev | rest], extra) do
    if String.trim(prev) == "" do
      [prev | append_parens_to_previous(rest, extra)]
    else
      [prev <> String.duplicate(")", extra) | rest]
    end
  end

  @spec collapse_blank_lines([String.t()]) :: [String.t()]
  defp collapse_blank_lines(lines) do
    {result, _} =
      Enum.reduce(lines, {[], 0}, fn line, {acc, blank_count} ->
        collapse_line(line, acc, blank_count)
      end)

    Enum.reverse(result)
  end

  @spec collapse_line(String.t(), [String.t()], non_neg_integer()) ::
          {[String.t()], non_neg_integer()}
  defp collapse_line(line, acc, blank_count) do
    case {String.trim(line) == "", blank_count < 2} do
      {true, true} -> {[line | acc], blank_count + 1}
      {true, false} -> {acc, blank_count + 1}
      {false, _} -> {[line | acc], 0}
    end
  end

  @spec write_version(String.t(), String.t()) :: :ok
  defp write_version(target_dir, commit) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    content = "nvim-treesitter @ #{commit}\nSynced on #{now}\n"
    File.write!(Path.join(target_dir, "VERSION"), content)
  end
end
