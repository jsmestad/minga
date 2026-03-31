defmodule MingaAgent.Memory do
  @moduledoc """
  Persistent user memory file for cross-session preferences and learnings.

  Reads from and writes to `~/.config/minga/MEMORY.md`. The file is
  automatically loaded into the agent's system prompt on every session,
  after AGENTS.md instructions and before skills.

  The memory file is plain Markdown, user-editable outside the editor.
  Entries are appended with timestamps so the user can see when each
  learning was recorded.
  """

  @memory_filename "MEMORY.md"
  @max_tokens 4000

  @typedoc "A memory entry with timestamp."
  @type entry :: %{
          text: String.t(),
          timestamp: String.t()
        }

  @doc """
  Returns the full path to the memory file.

  Accepts an optional `config_dir` override for testing. When nil (the
  default), uses `$XDG_CONFIG_HOME` or `~/.config`.
  """
  @spec path(String.t() | nil) :: String.t()
  def path(config_dir \\ nil) do
    base =
      config_dir || System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")

    Path.join([base, "minga", @memory_filename])
  end

  @doc """
  Reads the memory file and returns its content, or nil if it doesn't exist.
  """
  @spec read(String.t() | nil) :: String.t() | nil
  def read(config_dir \\ nil) do
    case File.read(path(config_dir)) do
      {:ok, ""} -> nil
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  @doc """
  Appends a line to the memory file with a timestamp.

  Creates the file and parent directories if they don't exist.
  """
  @spec append(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def append(text, config_dir \\ nil) when is_binary(text) do
    file_path = path(config_dir)
    dir = Path.dirname(file_path)

    with :ok <- File.mkdir_p(dir) do
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")
      line = "- [#{timestamp}] #{String.trim(text)}\n"

      File.write(file_path, line, [:append])
    end
  end

  @doc """
  Returns the memory content formatted for inclusion in the system prompt.

  Returns nil if no memory exists or the file is empty. Includes a warning
  when the memory file is approaching the token budget.
  """
  @spec for_prompt(String.t() | nil) :: String.t() | nil
  def for_prompt(config_dir \\ nil) do
    case read(config_dir) do
      nil ->
        nil

      content ->
        # Rough token estimate: ~4 chars per token. Can be off by 2x for
        # code-heavy content, but good enough for a size warning.
        estimated_tokens = div(String.length(content), 4)

        warning =
          if estimated_tokens > @max_tokens * 0.8 do
            "\n\n⚠️ Memory file is #{estimated_tokens}/#{@max_tokens} estimated tokens. Consider trimming old entries."
          else
            ""
          end

        "## User Memory\n\n" <>
          "The following are persistent learnings and preferences from previous sessions:\n\n" <>
          content <> warning
    end
  end

  @doc """
  Shows the current memory file content with stats.
  """
  @spec summary(String.t() | nil) :: String.t()
  def summary(config_dir \\ nil) do
    case read(config_dir) do
      nil ->
        "No memory file found at #{path(config_dir)}\n" <>
          "Use /remember <text> to start building your memory."

      content ->
        lines = String.split(content, "\n", trim: true)
        estimated_tokens = div(String.length(content), 4)

        "Memory file: #{path(config_dir)}\n" <>
          "  Entries: #{length(lines)}\n" <>
          "  Estimated tokens: #{estimated_tokens}/#{@max_tokens}\n\n" <>
          content
    end
  end

  @doc """
  Clears the memory file.
  """
  @spec clear(String.t() | nil) :: :ok | {:error, term()}
  def clear(config_dir \\ nil) do
    case File.rm(path(config_dir)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
