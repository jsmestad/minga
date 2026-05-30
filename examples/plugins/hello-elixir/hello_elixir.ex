defmodule MingaHelloElixir do
  @moduledoc "Example Elixir plugin demonstrating use Minga.Extension.Agent."

  use Minga.Extension.Agent

  hook :session_start, command: "#{__DIR__}/hooks/hello.sh"

  slash_command :greet_elixir, "Say hello from the Elixir example plugin",
    command: "#{__DIR__}/hooks/hello.sh"

  @impl true
  def name, do: :hello_elixir

  @impl true
  def description, do: "Example Elixir agent plugin"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config), do: {:ok, %{}}
end
