defmodule Minga.Command.ParserTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Command.Parser

  describe "parse/1 basics" do
    test "write, quit, edit, buffer navigation, line jumps, and unknown commands" do
      assert_parse_cases([
        {"w", {:save, []}},
        {"  w  ", {:save, []}},
        {"q", {:quit, []}},
        {"q!", {:force_quit, []}},
        {"wq", {:save_quit, []}},
        {"wqa", {:save_quit_all, []}},
        {"wqall", {:save_quit_all, []}},
        {"qa", {:quit_all, []}},
        {"qa!", {:force_quit_all, []}},
        {"qall", {:quit_all, []}},
        {"qall!", {:force_quit_all, []}},
        {"cq", {:abort_quit, []}},
        {"cquit", {:abort_quit, []}},
        {"cq!", {:abort_quit, []}},
        {"cquit!", {:abort_quit, []}},
        {"e README.md", {:edit, "README.md"}},
        {"e my file.txt", {:edit, "my file.txt"}},
        {"e", {:unknown, "e"}},
        {"buffers", {:buffers, []}},
        {"ls", {:buffers, []}},
        {"bnext", {:buffer_next, []}},
        {"bn", {:buffer_next, []}},
        {"bprev", {:buffer_prev, []}},
        {"bp", {:buffer_prev, []}},
        {"42", {:goto_line, 42}},
        {"1", {:goto_line, 1}},
        {"999", {:goto_line, 999}},
        {"0", {:unknown, "0"}},
        {"-5", {:unknown, "-5"}},
        {"xyz", {:unknown, "xyz"}},
        {"", {:unknown, ""}},
        {"wo", {:unknown, "wo"}},
        {"agent-provider native", {:unknown, "agent-provider native"}}
      ])
    end
  end

  describe "options and filetypes" do
    test "set, setglobal, and set filetype aliases map to option commands" do
      assert_parse_cases([
        {"set number", {:set, :number}},
        {"set nu", {:set, :number}},
        {"set nonumber", {:set, :nonumber}},
        {"set nonu", {:set, :nonumber}},
        {"set relativenumber", {:set, :relativenumber}},
        {"set rnu", {:set, :relativenumber}},
        {"set norelativenumber", {:set, :norelativenumber}},
        {"set nornu", {:set, :norelativenumber}},
        {"setglobal number", {:setglobal, :number}},
        {"setglobal nu", {:setglobal, :number}},
        {"setglobal nonumber", {:setglobal, :nonumber}},
        {"setglobal nonu", {:setglobal, :nonumber}},
        {"setglobal relativenumber", {:setglobal, :relativenumber}},
        {"setglobal rnu", {:setglobal, :relativenumber}},
        {"setglobal norelativenumber", {:setglobal, :norelativenumber}},
        {"setglobal nornu", {:setglobal, :norelativenumber}},
        {"setglobal wrap", {:setglobal, :wrap}},
        {"setglobal nowrap", {:setglobal, :nowrap}},
        {"set ft=python", {:set_filetype, ["python"]}},
        {"set filetype=elixir", {:set_filetype, ["elixir"]}},
        {"setf ruby", {:set_filetype, ["ruby"]}},
        {"setfiletype go", {:set_filetype, ["go"]}},
        {"set ft=  python  ", {:set_filetype, ["python"]}}
      ])
    end
  end

  describe "substitute and ranges" do
    test "substitute handles whole-buffer ranges, flags, missing trailing delimiters, escaped delimiters, empty replacements, and alternate delimiters" do
      assert_parse_cases([
        {"%s/old/new/", {:substitute, "old", "new", []}},
        {"%s/old/new/g", {:substitute, "old", "new", [:global]}},
        {"s/old/new/", {:substitute, "old", "new", []}},
        {"%s/old/new/gc", {:substitute, "old", "new", [:global, :confirm]}},
        {"%s/old/new", {:substitute, "old", "new", []}},
        {"%s/a\\/b/c/", {:substitute, "a\\/b", "c", []}},
        {"%s/old//g", {:substitute, "old", "", [:global]}},
        {"%s#old#new#g", {:substitute, "old", "new", [:global]}}
      ])
    end
  end

  describe "help, agent, and parser commands" do
    test "describe, agent, and parser restart commands parse their arguments and aliases" do
      assert_parse_cases([
        {"describe", {:describe_option, []}},
        {"describe tab_width", {:describe_option_named, ["tab_width"]}},
        {"describe-command", {:describe_command, []}},
        {"describe-command save", {:describe_command_named, ["save"]}},
        {"describe-command   save  ", {:describe_command_named, ["save"]}},
        {"agent-clear-history", {:agent_clear_history, []}},
        {"agent-stop", {:agent_abort, []}},
        {"agent-new", {:agent_new_session, []}},
        {"parser-restart", {:parser_restart, []}},
        {"ParserRestart", {:parser_restart, []}},
        {"terminal", {:terminal, []}},
        {"reload-highlights", {:reload_highlights, []}},
        {"rh", {:reload_highlights, []}}
      ])
    end
  end

  describe "sort, read, shell, and global commands" do
    test "sort parses whole-buffer and explicit ranges with combinable flags" do
      assert_parse_cases([
        {"sort", {:sort, :whole_buffer, []}},
        {"sort r", {:sort, :whole_buffer, [:reverse]}},
        {"sort n", {:sort, :whole_buffer, [:numeric]}},
        {"sort rn", {:sort, :whole_buffer, [:reverse, :numeric]}},
        {"sort ru", {:sort, :whole_buffer, [:reverse, :unique]}},
        {"%sort", {:sort, :whole_buffer, []}},
        {"1,10sort", {:sort, {:absolute, 1, 10}, []}},
        {"1,10sort r", {:sort, {:absolute, 1, 10}, [:reverse]}}
      ])
    end

    test "read, shell, and global commands preserve arguments" do
      assert_parse_cases([
        {"read file.txt", {:read, "file.txt"}},
        {"r file.txt", {:read, "file.txt"}},
        {"read path/to/file.txt", {:read, "path/to/file.txt"}},
        {"read", {:unknown, "read"}},
        {"!ls", {:shell_command, "ls"}},
        {"!make test", {:shell_command, "make test"}},
        {"!", {:shell_command, ""}},
        {"g/pattern/cmd", {:global, "pattern", "cmd"}},
        {"g/foo/delete", {:global, "foo", "delete"}},
        {"g/test/s/old/new/g", {:global, "test", "s/old/new/g"}},
        {"gpattern", {:unknown, "gpattern"}}
      ])
    end
  end

  describe "normal command" do
    test "normal and norm parse key strings with supported ranges and reject missing keys" do
      assert_parse_cases([
        {"normal dd", {:normal, :whole_buffer, "dd"}},
        {"norm w", {:normal, :whole_buffer, "w"}},
        {"normal j", {:normal, :whole_buffer, "j"}},
        {"normal dw", {:normal, :whole_buffer, "dw"}},
        {"normal ^d", {:normal, :whole_buffer, "^d"}},
        {"normal gJ", {:normal, :whole_buffer, "gJ"}},
        {"%normal dd", {:normal, :whole_buffer, "dd"}},
        {"1,5normal w", {:normal, {:absolute, 1, 5}, "w"}},
        {".normal dd", {:normal, :current_line, "dd"}},
        {"$normal dd", {:normal, :last_line, "dd"}},
        {"normal", {:unknown, "normal"}},
        {"norm", {:unknown, "norm"}},
        {"normal    ", {:unknown, "normal"}}
      ])
    end
  end

  describe "dired / oil" do
    test "dired and oil parse optional paths" do
      assert_parse_cases([
        {"dired", {:dired, nil}},
        {"oil", {:dired, nil}},
        {"dired /tmp/foo", {:dired, "/tmp/foo"}},
        {"oil /tmp/foo", {:dired, "/tmp/foo"}},
        {"dired   ", {:dired, nil}},
        {"oil   ", {:dired, nil}}
      ])
    end
  end

  defp assert_parse_cases(cases) do
    for {input, expected} <- cases do
      assert normalize(Parser.parse(input)) == normalize(expected),
             "expected #{inspect(input)} to parse as #{inspect(expected)}"
    end
  end

  defp normalize({:substitute, old, new, flags}), do: {:substitute, old, new, Enum.sort(flags)}
  defp normalize({:sort, range, flags}), do: {:sort, range, Enum.sort(flags)}
  defp normalize(other), do: other
end
