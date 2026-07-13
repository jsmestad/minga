defmodule MingaEditor.LSP.FormatLifecycle do
  @moduledoc "Coordinates timers and LSP cancellation for formatting operations."

  alias Minga.LSP.Client
  alias Minga.LSP.PositionEncoding
  alias MingaEditor.State.LSP.FormatOperation

  @spinner_delay 100
  @cancel_delay 1_000
  @timeout 5_000

  @doc "Arms Editor feedback timers and builds one operation value."
  @spec arm(pid(), reference(), pid(), non_neg_integer(), PositionEncoding.encoding()) ::
          FormatOperation.t()
  def arm(client, ref, buffer, version, encoding)
      when is_pid(client) and is_reference(ref) and is_pid(buffer) and is_integer(version) and
             version >= 0 and encoding in [:utf8, :utf16, :utf32] do
    FormatOperation.new(
      client: client,
      ref: ref,
      buffer: buffer,
      version: version,
      encoding: encoding,
      spinner_timer: Process.send_after(self(), {:lsp_format_spinner, ref}, @spinner_delay),
      cancellable_timer:
        Process.send_after(self(), {:lsp_format_cancellable, ref}, @cancel_delay),
      timeout_timer: Process.send_after(self(), {:lsp_format_timeout, ref}, @timeout)
    )
  end

  @doc "Finishes Editor-owned timer lifecycle after a response."
  @spec finish(FormatOperation.t()) :: :ok
  def finish(%FormatOperation{} = operation) do
    Enum.each(FormatOperation.timer_refs(operation), &Process.cancel_timer/1)
  end

  @doc "Finishes timers and cancels the underlying LSP request."
  @spec cancel(FormatOperation.t()) :: :ok
  def cancel(%FormatOperation{} = operation) do
    finish(operation)
    Client.cancel_request(operation.client, operation.ref)
  end
end
