defmodule MingaEditor.Commands.StartBufferTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor.Commands

  @moduletag :tmp_dir

  describe "start_buffer/1" do
    test "returns an existing registered file buffer instead of starting a duplicate", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "already-open.ex")
      File.write!(path, "already open")
      existing = start_supervised!({Buffer, file_path: path})

      assert {:ok, ^existing} = Commands.start_buffer(path)
      assert {:ok, ^existing} = Buffer.pid_for_path(path)
    end

    test "uses the supplied options server when starting a new buffer", %{tmp_dir: tmp_dir} do
      options_server = start_supervised!({Options, name: __MODULE__})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      path = Path.join(tmp_dir, "custom-options.txt")
      File.write!(path, "hello")

      assert {:ok, pid} = Commands.start_buffer(path, options_server)
      assert BufferProcess.get_option(pid, :autopair_block) == false
    end
  end
end
