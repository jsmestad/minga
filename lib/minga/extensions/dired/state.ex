defmodule Minga.Extensions.Dired.State do
  @moduledoc """
  Dired sub-state: directory listing data, backing buffer, and original entries snapshot.

  Tracks the Oil.nvim-style directory buffer state within a workspace.
  The `original_entries` field holds the snapshot taken when the buffer
  was last populated, used as the baseline for diffing on save.
  """

  alias Minga.Extensions.Dired.Core, as: Dired

  @type t :: %__MODULE__{
          active?: boolean(),
          dired: Dired.t() | nil,
          buffer: pid() | nil,
          original_entries: [Dired.entry()],
          confirming?: boolean(),
          pending_ops: [Dired.operation()],
          pending_prefix: Minga.Keymap.Bindings.node_t() | nil
        }

  defstruct active?: false,
            dired: nil,
            buffer: nil,
            original_entries: [],
            confirming?: false,
            pending_ops: [],
            pending_prefix: nil

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{active?: active}), do: active

  @spec activate(t(), Dired.t(), pid()) :: t()
  def activate(%__MODULE__{} = state, %Dired{} = dired, buffer_pid) do
    %{state | active?: true, dired: dired, buffer: buffer_pid, original_entries: dired.entries}
  end

  @spec deactivate(t()) :: t()
  def deactivate(%__MODULE__{}) do
    %__MODULE__{}
  end

  @spec update_dired(t(), Dired.t()) :: t()
  def update_dired(%__MODULE__{} = state, %Dired{} = dired) do
    %{state | dired: dired, original_entries: dired.entries}
  end

  @spec enter_confirmation(t(), [Dired.operation()]) :: t()
  def enter_confirmation(%__MODULE__{} = state, ops) do
    %{state | confirming?: true, pending_ops: ops}
  end

  @spec exit_confirmation(t()) :: t()
  def exit_confirmation(%__MODULE__{} = state) do
    %{state | confirming?: false, pending_ops: []}
  end

  @doc "Sets the pending keymap prefix node."
  @spec set_pending_prefix(t(), Minga.Keymap.Bindings.node_t() | nil) :: t()
  def set_pending_prefix(%__MODULE__{} = state, prefix), do: %{state | pending_prefix: prefix}
end
