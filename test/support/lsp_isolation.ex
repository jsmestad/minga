defmodule Minga.Test.LspIsolation do
  @moduledoc false

  alias Minga.LSP.Supervisor, as: LSPSupervisor

  @spec stop_lsp_clients() :: :ok
  def stop_lsp_clients do
    for pid <- LSPSupervisor.all_clients() do
      DynamicSupervisor.terminate_child(LSPSupervisor, pid)
    end

    :ok
  catch
    :exit, _ -> :ok
  end
end
