defmodule MingaAgent.Changeset.ToolRouter do
  @moduledoc """
  Routes file tool operations through a changeset when one is active.

  Tools call this module instead of directly doing filesystem I/O or
  buffer operations. If a changeset pid is provided (not nil), operations
  go through `MingaAgent.Changeset`. Otherwise, they fall through to the
  original tool behavior (buffer or filesystem).

  This module is stateless. The changeset pid comes from the caller
  (typically stored in the session's state). Tools don't need to know
  whether a changeset is active; they call these functions and the
  routing happens transparently.
  """

  alias MingaAgent.Changeset

  @type changeset :: pid() | nil

  @doc """
  Reads a file, routing through the changeset if active.

  When a changeset is active, returns the changeset's view of the file
  (modified content if edited, original otherwise). When no changeset,
  delegates to the standard read path (buffer or filesystem).
  """
  @spec read_file(changeset(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(nil, path) do
    case Minga.Buffer.pid_for_path(path) do
      {:ok, pid} ->
        {:ok, Minga.Buffer.content(pid)}

      :not_found ->
        File.read(path)
    end
  catch
    :exit, _ -> File.read(path)
  end

  def read_file(cs, path) when is_pid(cs) do
    relative = normalize_tool_path(cs, path)
    Changeset.read_file(cs, relative)
  end

  @doc """
  Writes a file, routing through the changeset if active.

  When a changeset is active, writes to the changeset overlay only.
  The real project file is not modified until the changeset is merged.
  """
  @spec write_file(changeset(), String.t(), binary()) :: :ok | :passthrough | {:error, term()}
  def write_file(nil, _path, _content), do: :passthrough

  def write_file(cs, path, content) when is_pid(cs) do
    relative = normalize_tool_path(cs, path)
    Changeset.write_file(cs, relative, content)
  end

  @doc """
  Edits a file by find-and-replace, routing through the changeset if active.
  """
  @spec edit_file(changeset(), String.t(), String.t(), String.t()) ::
          :ok | :passthrough | {:error, term()}
  def edit_file(nil, _path, _old_text, _new_text), do: :passthrough

  def edit_file(cs, path, old_text, new_text) when is_pid(cs) do
    relative = normalize_tool_path(cs, path)
    Changeset.edit_file(cs, relative, old_text, new_text)
  end

  @doc """
  Deletes a file, routing through the changeset if active.
  """
  @spec delete_file(changeset(), String.t()) :: :ok | :passthrough | {:error, term()}
  def delete_file(nil, _path), do: :passthrough

  def delete_file(cs, path) when is_pid(cs) do
    relative = normalize_tool_path(cs, path)
    Changeset.delete_file(cs, relative)
  end

  @doc """
  Returns the working directory for shell commands.

  When a changeset is active, returns the overlay directory so commands
  see the changeset's view of the project. Otherwise returns nil (caller
  uses the real project root).
  """
  @spec working_dir(changeset()) :: String.t() | nil
  def working_dir(nil), do: nil

  def working_dir(cs) when is_pid(cs) do
    Changeset.overlay_path(cs)
  end

  @doc """
  Returns true if a changeset is active (non-nil pid that's still alive).
  """
  @spec active?(changeset()) :: boolean()
  def active?(nil), do: false
  def active?(cs) when is_pid(cs), do: Process.alive?(cs)

  # ── Private ─────────────────────────────────────────────────────────────────

  # Normalize a tool path: strip leading slashes and "./" for consistent
  # relative paths. Tools in `MingaAgent.Tools` already resolve paths
  # against the project root via `resolve_and_validate_path!/2`, so the
  # path passed here is always absolute. We convert it to a relative path
  # by stripping the project root prefix, or falling back to basename
  # normalization.
  @spec normalize_tool_path(pid(), String.t()) :: String.t()
  defp normalize_tool_path(cs, path) do
    root = Changeset.project_root(cs)

    path
    |> Path.relative_to(root)
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end
end
