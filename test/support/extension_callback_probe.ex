defmodule Minga.Test.ExtensionCallbackProbe do
  @moduledoc false

  @spec return(term()) :: term()
  def return(value), do: value

  @spec source_identity() :: term()
  def source_identity, do: Minga.Extension.InvocationContext.current_source()

  @spec notify_and_return(pid(), term()) :: term()
  def notify_and_return(owner, value) do
    send(owner, {:extension_callback_entered, value})
    value
  end

  @spec raise_error() :: no_return()
  def raise_error, do: raise("callback exploded")

  @spec throw_error() :: no_return()
  def throw_error, do: throw(:callback_thrown)

  @spec exit_error() :: no_return()
  def exit_error, do: exit(:callback_exited)
end
