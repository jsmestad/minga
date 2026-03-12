defmodule Minga.Agent.Instructions do
  @moduledoc """
  Multi-level AGENTS.md discovery and assembly.

  Discovers instruction files from multiple locations and layers them
  into the system prompt. Files are checked in order, and all found
  files are included with section headers showing their source path.

  ## Discovery order

  1. **Global**: `~/.config/minga/AGENTS.md` (user-wide defaults)
  2. **Project root**: `AGENTS.md` at the project root
  3. **Project config**: `.minga/AGENTS.md` at the project root
  4. **Directory-scoped**: `AGENTS.md` files in parent directories between
     the current file's directory and the project root (for monorepo subdirectory rules)

  Global instructions come first, project instructions next, directory-scoped
  instructions last (most specific wins when instructions conflict).
  """

  @typedoc "A discovered instruction file."
  @type instruction :: %{
          label: String.t(),
          path: String.t(),
          content: String.t()
        }

  @doc """
  Discovers all instruction files and returns them as an ordered list.

  `project_root` is the project root directory. `current_file` is the
  path of the file the user is currently editing (optional, used for
  directory-scoped discovery in monorepos).
  """
  @spec discover(String.t(), String.t() | nil) :: [instruction()]
  def discover(project_root, current_file \\ nil) when is_binary(project_root) do
    global_instructions() ++
      project_instructions(project_root) ++
      directory_instructions(project_root, current_file)
  end

  @doc """
  Assembles discovered instructions into a single string with section headers.

  Returns nil if no instruction files were found.
  """
  @spec assemble(String.t(), String.t() | nil) :: String.t() | nil
  def assemble(project_root, current_file \\ nil) do
    instructions = discover(project_root, current_file)

    case instructions do
      [] ->
        nil

      found ->
        Enum.map_join(found, "\n\n", fn %{label: label, content: content} ->
          "## #{label}\n\n#{String.trim(content)}"
        end)
    end
  end

  @doc """
  Returns a summary of discovered instruction files (paths and sizes).

  Useful for the `/instructions` slash command.
  """
  @spec summary(String.t(), String.t() | nil) :: String.t()
  def summary(project_root, current_file \\ nil) do
    instructions = discover(project_root, current_file)

    case instructions do
      [] ->
        "No instruction files found.\n\nSearched:\n" <>
          "  ~/.config/minga/AGENTS.md\n" <>
          "  #{project_root}/AGENTS.md\n" <>
          "  #{project_root}/.minga/AGENTS.md"

      found ->
        header = "Loaded #{length(found)} instruction file(s):\n"

        lines =
          Enum.map_join(found, "\n", fn %{label: label, path: path, content: content} ->
            size = String.length(content)
            "  ✓ #{label} (#{path}, #{size} chars)"
          end)

        header <> lines
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec global_instructions() :: [instruction()]
  defp global_instructions do
    config_dir = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    path = Path.join([config_dir, "minga", "AGENTS.md"])
    read_instruction("Global Instructions", path)
  end

  @spec project_instructions(String.t()) :: [instruction()]
  defp project_instructions(project_root) do
    root_path = Path.join(project_root, "AGENTS.md")
    config_path = Path.join([project_root, ".minga", "AGENTS.md"])

    read_instruction("Project Instructions", root_path) ++
      read_instruction("Project Config Instructions", config_path)
  end

  @spec directory_instructions(String.t(), String.t() | nil) :: [instruction()]
  defp directory_instructions(_project_root, nil), do: []

  defp directory_instructions(project_root, current_file) do
    file_dir = Path.dirname(current_file)
    abs_root = Path.expand(project_root)
    abs_dir = Path.expand(file_dir)

    walk_up(abs_dir, abs_root)
  end

  # Walks up from `dir` toward `root`, collecting AGENTS.md files at each level.
  # Skips the root itself (already handled by project_instructions).
  # Returns files ordered from root-adjacent to most specific (deepest first reversed).
  @spec walk_up(String.t(), String.t()) :: [instruction()]
  defp walk_up(dir, root) when dir == root, do: []

  defp walk_up(dir, root) do
    if String.starts_with?(dir, root) do
      parent = Path.dirname(dir)
      parent_results = walk_up(parent, root)

      path = Path.join(dir, "AGENTS.md")
      relative = Path.relative_to(path, root)
      label = "Directory Instructions (#{relative})"

      parent_results ++ read_instruction(label, path)
    else
      []
    end
  end

  @spec read_instruction(String.t(), String.t()) :: [instruction()]
  defp read_instruction(label, path) do
    case File.read(path) do
      {:ok, content} when content != "" ->
        [%{label: label, path: path, content: content}]

      _ ->
        []
    end
  end
end
