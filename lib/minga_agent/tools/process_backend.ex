defmodule MingaAgent.Tools.ProcessBackend do
  @moduledoc """
  Behaviour for the process-backed agent tools.

  `MingaAgent.Tools` owns tool routing, validation, and workspace context. Implementations of this behaviour execute already-resolved find, grep, and shell requests.
  """

  @type search_opts :: keyword()
  @type shell_opts :: keyword()
  @type incomplete_result :: {:incomplete, MingaAgent.Tool.Output.incomplete_reason(), binary()}
  @type result ::
          {:ok, String.t() | MingaAgent.Tool.Output.t()}
          | {:error, String.t() | incomplete_result() | MingaAgent.Tool.Output.t() | term()}

  @callback find(String.t(), String.t(), map(), search_opts()) :: result()
  @callback grep(String.t(), String.t(), map(), search_opts()) :: result()
  @callback shell(String.t(), String.t(), pos_integer(), shell_opts()) :: result()
end
