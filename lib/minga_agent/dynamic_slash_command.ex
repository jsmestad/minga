defmodule MingaAgent.DynamicSlashCommand do
  @moduledoc "Executes one extension-contributed slash command outside the Editor process."

  @type result :: {String.t(), non_neg_integer()}

  @doc """
  Runs the declared executable with already normalized arguments.

  `directory` is where it runs: the open project's root, so a relative path in its arguments means "in the project". With `nil` it runs where Minga runs.
  """
  @spec run(String.t(), [String.t()]) :: result()
  @spec run(String.t(), [String.t()], String.t() | nil) :: result()
  def run(command_path, command_args, directory \\ nil)
      when is_binary(command_path) and is_list(command_args) do
    System.cmd(command_path, command_args, [stderr_to_stdout: true] ++ in_directory(directory))
  end

  @spec in_directory(String.t() | nil) :: [{:cd, String.t()}]
  defp in_directory(directory) when is_binary(directory), do: [cd: directory]
  defp in_directory(nil), do: []
end
