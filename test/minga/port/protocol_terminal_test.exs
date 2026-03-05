defmodule Minga.Port.Protocol.TerminalTest do
  use ExUnit.Case, async: true

  alias Minga.Port.Protocol

  describe "encode_open_terminal/7" do
    test "encodes shell path, dimensions, and theme colors" do
      cmd = Protocol.encode_open_terminal("/bin/zsh", 24, 80, 10, 0, 0xBBC2CF, 0x282C34)

      assert <<0x40, shell_len::16, shell::binary-size(shell_len), rows::16, cols::16,
               row_off::16, col_off::16, fg::24, bg::24>> = cmd

      assert shell == "/bin/zsh"
      assert rows == 24
      assert cols == 80
      assert row_off == 10
      assert col_off == 0
      assert fg == 0xBBC2CF
      assert bg == 0x282C34
    end
  end

  describe "encode_close_terminal/0" do
    test "encodes single opcode byte" do
      assert Protocol.encode_close_terminal() == <<0x41>>
    end
  end

  describe "encode_resize_terminal/4" do
    test "encodes dimensions and offsets" do
      cmd = Protocol.encode_resize_terminal(30, 100, 15, 5)
      assert <<0x42, 30::16, 100::16, 15::16, 5::16>> = cmd
    end
  end

  describe "encode_terminal_input/1" do
    test "encodes input data with length prefix" do
      cmd = Protocol.encode_terminal_input("hello")
      assert <<0x43, 5::16, "hello">> = cmd
    end

    test "handles empty input" do
      cmd = Protocol.encode_terminal_input("")
      assert <<0x43, 0::16>> = cmd
    end
  end

  describe "encode_terminal_focus/1" do
    test "encodes true as 1" do
      assert Protocol.encode_terminal_focus(true) == <<0x44, 1>>
    end

    test "encodes false as 0" do
      assert Protocol.encode_terminal_focus(false) == <<0x44, 0>>
    end
  end

  describe "decode_event terminal_exited" do
    test "decodes exit code 0" do
      assert {:ok, {:terminal_exited, 0}} = Protocol.decode_event(<<0x50, 0::32-signed>>)
    end

    test "decodes negative exit code" do
      assert {:ok, {:terminal_exited, -1}} = Protocol.decode_event(<<0x50, -1::32-signed>>)
    end
  end
end
