defmodule Minga.Picker.OptionScopeSource do
  @moduledoc """
  Picker source for choosing the scope of an option toggle.

  When a user toggles a buffer-local option from the command palette,
  this source presents two choices: "This Buffer" (writes to the
  buffer's local options) and "All Buffers (Default)" (writes to the
  global Options agent, affecting all buffers without a local override).

  The picker context (stored in `state.picker_ui.context`) must include:

  * `:option_name` — the option atom
  * `:new_value` — the computed new value
  * `:command_description` — human-readable label for the title
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options

  @impl true
  @spec title() :: String.t()
  def title, do: "Apply to..."

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(_context) do
    [
      {:buffer, "This Buffer", "Set for the current buffer only"},
      {:global, "All Buffers (Default)", "Set the default for all buffers without a local override"}
    ]
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({scope, _, _}, state) when scope in [:buffer, :global] do
    ctx = state.picker_ui.context
    apply_scoped(scope, ctx.option_name, ctx.new_value, state)
  end

  def on_select(_, state), do: state

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec apply_scoped(:buffer | :global, atom(), term(), term()) :: term()
  defp apply_scoped(:buffer, name, value, state) do
    buf = state.buffers.active

    if is_pid(buf) do
      BufferServer.set_option(buf, name, value)
    end

    %{state | status_msg: format_confirmation(name, value, "this buffer")}
  end

  defp apply_scoped(:global, name, value, state) do
    Options.set(name, value)
    %{state | status_msg: format_confirmation(name, value, "all buffers")}
  end

  @spec format_confirmation(atom(), term(), String.t()) :: String.t()
  defp format_confirmation(name, value, scope) do
    "#{name} = #{inspect(value)} (#{scope})"
  end
end
