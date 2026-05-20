defmodule Minga.Project.FileRef do
  @moduledoc """
  Logical file identity for workspace membership.

  A file ref identifies the user's logical file, not a future backend or overlay path. Path refs are scoped to an expanded project root plus a normalized relative path. Buffer refs identify unsaved or special buffers by their live buffer pid.
  """

  alias Minga.Buffer

  @type kind :: :path | :buffer

  @type t :: %__MODULE__{
          kind: kind(),
          project_root: String.t() | nil,
          relative_path: String.t() | nil,
          display_name: String.t(),
          buffer_pid: pid() | nil
        }

  @enforce_keys [:kind, :display_name]
  defstruct kind: nil,
            project_root: nil,
            relative_path: nil,
            display_name: "",
            buffer_pid: nil

  @doc "Builds a path-backed logical file ref scoped to a project root."
  @spec from_path(String.t(), String.t()) :: {:ok, t()} | {:error, :outside_project}
  def from_path(project_root, path) when is_binary(project_root) and is_binary(path) do
    root = Path.expand(project_root)
    expanded_path = expand_path(root, path)

    if inside_root?(expanded_path, root) do
      relative_path = Path.relative_to(expanded_path, root)

      {:ok,
       %__MODULE__{
         kind: :path,
         project_root: root,
         relative_path: relative_path,
         display_name: Path.basename(relative_path),
         buffer_pid: nil
       }}
    else
      {:error, :outside_project}
    end
  end

  @doc "Builds a buffer-backed logical file ref for an unsaved or special buffer."
  @spec from_buffer(pid()) :: t()
  def from_buffer(buffer_pid) when is_pid(buffer_pid) do
    %__MODULE__{
      kind: :buffer,
      project_root: nil,
      relative_path: nil,
      display_name: buffer_display_name(buffer_pid),
      buffer_pid: buffer_pid
    }
  end

  @doc "Returns true when two refs identify the same logical file."
  @spec equal?(t() | nil, t() | nil) :: boolean()
  def equal?(%__MODULE__{kind: :path, project_root: root, relative_path: path}, %__MODULE__{
        kind: :path,
        project_root: root,
        relative_path: path
      }),
      do: true

  def equal?(%__MODULE__{kind: :buffer, buffer_pid: pid}, %__MODULE__{
        kind: :buffer,
        buffer_pid: pid
      })
      when is_pid(pid),
      do: true

  def equal?(_, _), do: false

  @doc "Returns the display label for a file ref."
  @spec display_label(t()) :: String.t()
  def display_label(%__MODULE__{display_name: name}), do: name

  @spec expand_path(String.t(), String.t()) :: String.t()
  defp expand_path(root, path) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _ -> Path.expand(path, root)
    end
  end

  @spec inside_root?(String.t(), String.t()) :: boolean()
  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  @spec buffer_display_name(pid()) :: String.t()
  defp buffer_display_name(buffer_pid) do
    Buffer.display_name(buffer_pid)
  catch
    :exit, _ -> "[dead]"
  end
end
