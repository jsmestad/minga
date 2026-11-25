defmodule MingaAgent.Tools.LspSymlinkTest do
  # async: false: registers fake clients in the shared SyncServer and publishes to the shared Diagnostics store.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias Minga.Project.Root
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tools.DiagnosticFeedback
  alias MingaAgent.Tools.LspCodeActions
  alias MingaAgent.Tools.LspDefinition
  alias MingaAgent.Tools.LspDiagnostics
  alias MingaAgent.Tools.LspDocumentSymbols
  alias MingaAgent.Tools.LspHover
  alias MingaAgent.Tools.LspReferences
  alias MingaAgent.Tools.LspRename

  @moduletag :tmp_dir

  # The disk holds different text than the unsaved buffer, so a position
  # computed from the disk is visibly wrong. In the buffer, `foo` starts at
  # byte 9 and at UTF-16 character 6.
  @disk_content "x = foo()\n"
  @buffer_content "é😀 = foo()\n"
  @foo_byte_col 9
  @foo_utf16 %{"line" => 0, "character" => 6}
  @diagnostic_source :lsp_symlink_test

  for kind <- [:file_link, :directory_link] do
    describe "a buffer opened through a #{kind}" do
      setup %{tmp_dir: tmp_dir} do
        open_through_link(tmp_dir, unquote(kind))
      end

      test "position requests name the buffer's URI and use the buffer's content", ctx do
        client = start_fake_client(%{"textDocument/hover" => {:ok, nil}}, ctx.buffer)

        assert {:ok, _} = LspHover.execute(ctx.real, 0, @foo_byte_col)

        assert_receive {:lsp_request, ^client, "textDocument/hover", params}
        assert params["textDocument"]["uri"] == ctx.link_uri
        assert params["position"] == @foo_utf16
      end

      test "every document tool addresses the server by the buffer's URI", ctx do
        client =
          start_fake_client(
            %{
              "textDocument/definition" => {:ok, nil},
              "textDocument/references" => {:ok, nil},
              "textDocument/documentSymbol" => {:ok, nil},
              "textDocument/codeAction" => {:ok, nil},
              "textDocument/prepareRename" => {:ok, nil}
            },
            ctx.buffer
          )

        context = ToolContext.new(project_root: ctx.root)

        LspDefinition.execute(ctx.real, 0, @foo_byte_col)
        LspReferences.execute(ctx.real, 0, @foo_byte_col)
        LspDocumentSymbols.execute(ctx.real)
        LspCodeActions.execute(context, ctx.real, 0, col: @foo_byte_col)
        LspRename.execute(context, ctx.real, 0, @foo_byte_col, "bar")

        for method <- [
              "textDocument/definition",
              "textDocument/references",
              "textDocument/documentSymbol",
              "textDocument/codeAction",
              "textDocument/prepareRename"
            ] do
          assert_receive {:lsp_request, ^client, ^method, params}
          assert params["textDocument"]["uri"] == ctx.link_uri, method
        end
      end

      test "a definition the server reports under the link is shown at the real path", ctx do
        location = %{
          "uri" => ctx.link_uri,
          "range" => %{"start" => @foo_utf16, "end" => @foo_utf16}
        }

        start_fake_client(%{"textDocument/definition" => {:ok, [location]}}, ctx.buffer)

        assert {:ok, result} = LspDefinition.execute(ctx.real, 0, @foo_byte_col)
        assert result =~ "Definition: #{ctx.real}:1:6"
        refute result =~ ctx.link
      end

      test "the diagnostics tool reports what the server published for the buffer", ctx do
        start_fake_client(%{}, ctx.buffer)
        publish_diagnostic(ctx.link_uri, "undefined function foo/0")

        assert {:ok, result} = LspDiagnostics.execute(ctx.real)
        assert result =~ "1 diagnostics (1 error)"
        assert result =~ "undefined function foo/0"
      end

      test "diagnostic feedback after an edit reports the server's diagnostics", ctx do
        start_fake_client(%{}, ctx.buffer)
        publish_diagnostic(ctx.link_uri, "undefined function foo/0")

        assert {:ok, summary} = DiagnosticFeedback.await(ctx.real, timeout: 200, quiet_period: 10)
        assert summary =~ "Diagnostics: 1 issues (1 error)"
        assert summary =~ "undefined function foo/0"
      end
    end
  end

  # Writes the real file, links to it, opens a buffer by the link name the
  # way a user opening the link does, and leaves an unsaved edit in it. The agent names the file by its
  # real path, which is what its path validation resolves to.
  @spec open_through_link(String.t(), :file_link | :directory_link) :: map()
  defp open_through_link(tmp_dir, :file_link) do
    real = Path.join(tmp_dir, "real.ex")
    File.write!(real, @disk_content)
    link = Path.join(tmp_dir, "link.ex")
    File.ln_s!(real, link)
    open_buffer(tmp_dir, real, link)
  end

  defp open_through_link(tmp_dir, :directory_link) do
    real_dir = Path.join(tmp_dir, "real_dir")
    File.mkdir_p!(real_dir)
    real = Path.join(real_dir, "code.ex")
    File.write!(real, @disk_content)
    File.ln_s!(real_dir, Path.join(tmp_dir, "linked"))
    open_buffer(tmp_dir, real, Path.join(tmp_dir, "linked/code.ex"))
  end

  @spec open_buffer(String.t(), String.t(), String.t()) :: map()
  defp open_buffer(root, real, link) do
    {:ok, real} = Root.canonical_path(real)
    buffer = start_supervised!({BufferProcess, file_path: link})
    :ok = Minga.Buffer.replace_content(buffer, @buffer_content)

    %{
      root: root,
      real: real,
      link: link,
      link_uri: "file://" <> link,
      buffer: buffer
    }
  end

  @spec publish_diagnostic(String.t(), String.t()) :: :ok
  defp publish_diagnostic(uri, message) do
    diagnostic = %Diagnostic{
      range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 1},
      severity: :error,
      message: message,
      source: "fake"
    }

    :ok = Diagnostics.publish(@diagnostic_source, uri, [diagnostic])
    on_exit(fn -> Diagnostics.clear(@diagnostic_source, uri) end)
  end

  @spec start_fake_client(%{String.t() => {:ok, term()} | {:error, term()}}, pid()) :: pid()
  defp start_fake_client(responses, buffer) do
    owner = self()
    client = spawn(fn -> fake_client_loop(responses, owner) end)
    on_exit(fn -> Process.exit(client, :kill) end)
    attach_clients(buffer, [client])
    client
  end

  @spec fake_client_loop(%{String.t() => {:ok, term()} | {:error, term()}}, pid()) :: no_return()
  defp fake_client_loop(responses, owner) do
    receive do
      {:"$gen_call", from, :encoding} ->
        GenServer.reply(from, :utf16)
        fake_client_loop(responses, owner)

      {:"$gen_cast", {:async_request, method, params, caller, ref}} ->
        send(owner, {:lsp_request, self(), method, params})
        send(caller, {:lsp_response, ref, Map.fetch!(responses, method)})
        fake_client_loop(responses, owner)
    end
  end

  # Registers fake clients in the shared SyncServer registry and removes only this buffer's entry.
  defp attach_clients(buffer, clients) do
    SyncServer.put_clients(buffer, clients)
    on_exit(fn -> SyncServer.remove_buffer(buffer) end)
  end
end
