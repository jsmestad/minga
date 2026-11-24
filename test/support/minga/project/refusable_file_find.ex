defmodule Minga.Project.RefusableFileFind do
  @moduledoc """
  A controllable file-discovery backend that refuses to start while the workspace root holds a refusal marker.

  Without the marker it behaves like `Minga.Project.SlowFileFind`, so a test can start one rebuild, write the marker, and make the next rebuild refuse. The marker lives in the test's own root, so no global state is shared between tests.
  """

  alias Minga.Project.Root
  alias Minga.Project.SlowFileFind

  @marker ".refuse_discovery"
  @reason "Project file discovery refused to start"

  @spec start(Root.t(), pid()) :: {:ok, pid()} | {:error, String.t()}
  def start(%Root{path: path} = root, owner) do
    if File.exists?(Path.join(path, @marker)) do
      {:error, @reason}
    else
      SlowFileFind.start(root, owner)
    end
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid), do: SlowFileFind.cancel(pid)

  @doc "Makes every later discovery start in `root_path` refuse."
  @spec refuse(String.t()) :: :ok
  def refuse(root_path) when is_binary(root_path),
    do: File.write!(Path.join(root_path, @marker), "")

  @doc "Returns the reason a refused start reports."
  @spec reason() :: String.t()
  def reason, do: @reason
end
