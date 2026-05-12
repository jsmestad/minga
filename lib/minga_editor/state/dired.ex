defmodule MingaEditor.State.Dired do
  @moduledoc """
  Dired sub-state: directory listing data, backing buffer, and original entries snapshot.

  Tracks the Oil.nvim-style directory buffer state within a workspace.
  The `original_entries` field holds the snapshot taken when the buffer
  was last populated, used as the baseline for diffing on save.
  """

  alias Minga.Dired

  @type t :: %__MODULE__{
          active?: boolean(),
          dired: Dired.t() | nil,
          buffer: pid() | nil,
          original_entries: [Dired.entry()],
          confirming?: boolean()
        }

  defstruct active?: false,
            dired: nil,
            buffer: nil,
            original_entries: [],
            confirming?: false

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

  @spec set_confirming(t(), boolean()) :: t()
  def set_confirming(%__MODULE__{} = state, confirming?) do
    %{state | confirming?: confirming?}
  end
end
