defmodule MingaAgent.Skills do
  @moduledoc """
  Skills system for context-aware prompt injection.

  Skills are Markdown files that provide specialized instructions for
  specific tasks. They live in `~/.config/minga/skills/` (global) and
  `.minga/skills/` (project-local). Each skill is a directory containing
  a `SKILL.md` file with YAML-style frontmatter and instruction body.

  ## Skill format

      ---
      name: plan
      description: Plan mode for complex tasks
      activates_on:
        - plan
        - design
        - scope
        - feature
      ---

      # Planning Instructions

      When planning a feature, always...

  ## Loading

  Skills can be activated:
  - Explicitly via `/skill:name` in chat
  - Automatically when user prompts match `activates_on` keywords

  Multiple skills can be active simultaneously.
  """

  @typedoc "A discovered skill with metadata and instructions."
  @type skill :: %{
          name: String.t(),
          description: String.t(),
          activates_on: [String.t()],
          instructions: String.t(),
          path: String.t(),
          source: :global | :project
        }

  @global_skills_dir "~/.config/minga/skills"
  @project_skills_dir ".minga/skills"

  # ── Discovery ───────────────────────────────────────────────────────────────

  @doc """
  Discovers all available skills from global and project directories.

  Project-local skills override global skills with the same name.
  """
  @spec discover(String.t() | nil) :: [skill()]
  def discover(project_root \\ nil) do
    global = discover_in(expand_global_dir(), :global)

    project =
      if project_root,
        do: discover_in(Path.join(project_root, @project_skills_dir), :project),
        else: []

    # Project skills override global skills with the same name
    merged =
      (global ++ project)
      |> Enum.group_by(& &1.name)
      |> Enum.map(fn {_name, skills} -> List.last(skills) end)
      |> Enum.sort_by(& &1.name)

    merged
  end

  @doc """
  Finds a skill by name from the discovered skills.
  """
  @spec find(String.t(), String.t() | nil) :: {:ok, skill()} | :not_found
  def find(name, project_root \\ nil) do
    case Enum.find(discover(project_root), &(&1.name == name)) do
      nil -> :not_found
      skill -> {:ok, skill}
    end
  end

  @doc """
  Returns skills whose `activates_on` keywords match the given text.

  Performs case-insensitive word boundary matching. A keyword "plan"
  matches "let's plan this" but not "airplane".
  """
  @spec auto_activate([skill()], String.t()) :: [skill()]
  def auto_activate(skills, text) do
    lower = String.downcase(text)
    words = String.split(lower, ~r/\W+/, trim: true)

    Enum.filter(skills, fn skill ->
      skill.activates_on != [] and
        Enum.any?(skill.activates_on, fn keyword ->
          String.downcase(keyword) in words
        end)
    end)
  end

  @doc """
  Formats active skills into a system prompt section.
  """
  @spec format_for_prompt([skill()]) :: String.t() | nil
  def format_for_prompt([]), do: nil

  def format_for_prompt(active_skills) do
    sections =
      Enum.map_join(active_skills, "\n\n", fn skill ->
        "### Skill: #{skill.name}\n\n#{resolve_references(skill)}"
      end)

    "## Active Skills\n\n#{sections}"
  end

  @doc """
  Returns a human-readable summary of all discovered skills.
  """
  @spec summary(String.t() | nil) :: String.t()
  def summary(project_root \\ nil) do
    skills = discover(project_root)

    if skills == [] do
      "No skills found. Create skills in ~/.config/minga/skills/ or .minga/skills/."
    else
      header = "Available skills (#{length(skills)}):\n"
      lines = Enum.map_join(skills, "\n", &format_skill_line/1)
      header <> lines
    end
  end

  @spec format_skill_line(skill()) :: String.t()
  defp format_skill_line(skill) do
    source_tag = if skill.source == :project, do: " [project]", else: " [global]"

    auto =
      if skill.activates_on != [],
        do: " (auto: #{Enum.join(skill.activates_on, ", ")})",
        else: ""

    "  /skill:#{skill.name} — #{skill.description}#{source_tag}#{auto}"
  end

  # ── Parsing ─────────────────────────────────────────────────────────────────

  @doc """
  Parses a SKILL.md file into a skill struct.

  Extracts YAML-style frontmatter (between `---` delimiters) for metadata
  and uses the remainder as instruction text.
  """
  @spec parse_skill_file(String.t(), :global | :project) :: {:ok, skill()} | {:error, term()}
  def parse_skill_file(path, source) do
    case File.read(path) do
      {:ok, content} ->
        {frontmatter, body} = split_frontmatter(content)
        metadata = parse_frontmatter(frontmatter)

        skill = %{
          name: metadata["name"] || Path.basename(Path.dirname(path)),
          description: metadata["description"] || "",
          activates_on: parse_list(metadata["activates_on"]),
          instructions: String.trim(body),
          path: path,
          source: source
        }

        {:ok, skill}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec discover_in(String.t(), :global | :project) :: [skill()]
  defp discover_in(dir, source) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.flat_map(&try_load_skill(dir, &1, source))
    else
      []
    end
  end

  @spec try_load_skill(String.t(), String.t(), :global | :project) :: [skill()]
  defp try_load_skill(dir, entry, source) do
    skill_file = Path.join([dir, entry, "SKILL.md"])

    if File.regular?(skill_file) do
      case parse_skill_file(skill_file, source) do
        {:ok, skill} -> [skill]
        {:error, _} -> []
      end
    else
      []
    end
  end

  @spec split_frontmatter(String.t()) :: {String.t(), String.t()}
  defp split_frontmatter(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n(.*)\z/s, content) do
      [_, frontmatter, body] -> {frontmatter, body}
      _ -> {"", content}
    end
  end

  @spec parse_frontmatter(String.t()) :: map()
  defp parse_frontmatter(""), do: %{}

  defp parse_frontmatter(text) do
    # Simple YAML-like parser for key: value and key:\n  - item lines
    text
    |> String.split("\n")
    |> parse_yaml_lines(%{}, nil)
  end

  @spec parse_yaml_lines([String.t()], map(), String.t() | nil) :: map()
  defp parse_yaml_lines([], acc, _current_key), do: acc

  defp parse_yaml_lines(["  - " <> item | rest], acc, current_key) when is_binary(current_key) do
    existing = Map.get(acc, current_key, [])
    acc = Map.put(acc, current_key, existing ++ [String.trim(item)])
    parse_yaml_lines(rest, acc, current_key)
  end

  defp parse_yaml_lines([line | rest], acc, _current_key) do
    case String.split(line, ":", parts: 2) do
      [key, ""] ->
        # Key with no inline value, start collecting list items
        parse_yaml_lines(rest, acc, String.trim(key))

      [key, value] ->
        trimmed_value = String.trim(value)
        parse_yaml_lines(rest, Map.put(acc, String.trim(key), trimmed_value), nil)

      _ ->
        parse_yaml_lines(rest, acc, nil)
    end
  end

  @spec parse_list(term()) :: [String.t()]
  defp parse_list(nil), do: []
  defp parse_list(list) when is_list(list), do: list
  defp parse_list(str) when is_binary(str), do: String.split(str, ~r/[,\s]+/, trim: true)

  @spec expand_global_dir() :: String.t()
  defp expand_global_dir do
    Path.expand(@global_skills_dir)
  end

  # Resolve relative file references in skill instructions.
  # Lines like `@include path/to/file.md` are replaced with the file contents.
  @spec resolve_references(skill()) :: String.t()
  defp resolve_references(skill) do
    skill_dir = Path.dirname(skill.path)

    skill.instructions
    |> String.split("\n")
    |> Enum.map_join("\n", &resolve_include_line(&1, skill_dir))
  end

  @spec resolve_include_line(String.t(), String.t()) :: String.t()
  defp resolve_include_line(line, skill_dir) do
    case Regex.run(~r/^@include\s+(.+)$/, String.trim(line)) do
      [_, ref_path] ->
        abs_path = Path.expand(ref_path, skill_dir)
        if File.regular?(abs_path), do: File.read!(abs_path), else: line

      _ ->
        line
    end
  end
end
