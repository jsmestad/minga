defmodule MingaAgent.DynamicSlashCommand do
  @moduledoc "Executes one extension-contributed slash command outside the Editor process."

  @type result :: {String.t(), non_neg_integer()}

  @doc "Runs the declared executable with already normalized arguments."
  @spec run(String.t(), [String.t()]) :: result()
  def run(command_path, command_args) when is_binary(command_path) and is_list(command_args) do
    System.cmd(command_path, command_args, stderr_to_stdout: true)
  end
end
