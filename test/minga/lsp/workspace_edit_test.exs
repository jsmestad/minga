defmodule Minga.LSP.WorkspaceEditTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.WorkspaceEdit

  describe "parse/1" do
    test "returns empty list for nil" do
      assert WorkspaceEdit.parse(nil) == []
    end

    test "returns empty list for non-map input" do
      assert WorkspaceEdit.parse("not a map") == []
      assert WorkspaceEdit.parse(42) == []
    end

    test "returns empty list for empty edit" do
      assert WorkspaceEdit.parse(%{}) == []
    end

    test "parses changes format with single file" do
      edit = %{
        "changes" => %{
          "file:///home/user/project/lib/foo.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 5, "character" => 4},
                "end" => %{"line" => 5, "character" => 10}
              },
              "newText" => "new_name"
            },
            %{
              "range" => %{
                "start" => %{"line" => 2, "character" => 8},
                "end" => %{"line" => 2, "character" => 14}
              },
              "newText" => "new_name"
            }
          ]
        }
      }

      result = WorkspaceEdit.parse(edit)
      assert length(result) == 1
      {path, edits} = hd(result)
      assert String.ends_with?(path, "lib/foo.ex")
      assert length(edits) == 2

      # Edits should be in reverse document order (line 5 before line 2)
      [first, second] = edits
      {{l1, _}, _, _} = first
      {{l2, _}, _, _} = second
      assert l1 > l2
    end

    test "parses changes format with multiple files" do
      edit = %{
        "changes" => %{
          "file:///project/a.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 0, "character" => 0},
                "end" => %{"line" => 0, "character" => 3}
              },
              "newText" => "foo"
            }
          ],
          "file:///project/b.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 1, "character" => 0},
                "end" => %{"line" => 1, "character" => 3}
              },
              "newText" => "bar"
            }
          ]
        }
      }

      result = WorkspaceEdit.parse(edit)
      assert length(result) == 2
      paths = Enum.map(result, fn {path, _} -> path end) |> Enum.sort()
      assert Enum.any?(paths, &String.ends_with?(&1, "a.ex"))
      assert Enum.any?(paths, &String.ends_with?(&1, "b.ex"))
    end

    test "parses documentChanges format" do
      edit = %{
        "documentChanges" => [
          %{
            "textDocument" => %{
              "uri" => "file:///project/lib/bar.ex",
              "version" => 1
            },
            "edits" => [
              %{
                "range" => %{
                  "start" => %{"line" => 10, "character" => 2},
                  "end" => %{"line" => 10, "character" => 8}
                },
                "newText" => "renamed"
              }
            ]
          }
        ]
      }

      result = WorkspaceEdit.parse(edit)
      assert length(result) == 1
      {path, edits} = hd(result)
      assert String.ends_with?(path, "lib/bar.ex")
      assert [{{10, 2}, {10, 8}, "renamed"}] = edits
    end

    test "documentChanges takes priority over changes" do
      edit = %{
        "documentChanges" => [
          %{
            "textDocument" => %{"uri" => "file:///project/a.ex", "version" => 1},
            "edits" => [
              %{
                "range" => %{
                  "start" => %{"line" => 0, "character" => 0},
                  "end" => %{"line" => 0, "character" => 1}
                },
                "newText" => "x"
              }
            ]
          }
        ],
        "changes" => %{
          "file:///project/b.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 0, "character" => 0},
                "end" => %{"line" => 0, "character" => 1}
              },
              "newText" => "y"
            }
          ]
        }
      }

      # documentChanges should take priority
      result = WorkspaceEdit.parse(edit)
      assert length(result) == 1
      {path, _} = hd(result)
      assert String.ends_with?(path, "a.ex")
    end

    test "sorts edits in reverse document order within a file" do
      edit = %{
        "changes" => %{
          "file:///project/test.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 1, "character" => 0},
                "end" => %{"line" => 1, "character" => 3}
              },
              "newText" => "a"
            },
            %{
              "range" => %{
                "start" => %{"line" => 10, "character" => 5},
                "end" => %{"line" => 10, "character" => 8}
              },
              "newText" => "b"
            },
            %{
              "range" => %{
                "start" => %{"line" => 5, "character" => 2},
                "end" => %{"line" => 5, "character" => 6}
              },
              "newText" => "c"
            }
          ]
        }
      }

      [{_path, edits}] = WorkspaceEdit.parse(edit)
      lines = Enum.map(edits, fn {{line, _}, _, _} -> line end)
      assert lines == [10, 5, 1]
    end

    test "handles edits on the same line sorted by column" do
      edit = %{
        "changes" => %{
          "file:///project/test.ex" => [
            %{
              "range" => %{
                "start" => %{"line" => 5, "character" => 10},
                "end" => %{"line" => 5, "character" => 15}
              },
              "newText" => "a"
            },
            %{
              "range" => %{
                "start" => %{"line" => 5, "character" => 2},
                "end" => %{"line" => 5, "character" => 5}
              },
              "newText" => "b"
            }
          ]
        }
      }

      [{_path, edits}] = WorkspaceEdit.parse(edit)
      cols = Enum.map(edits, fn {{_, col}, _, _} -> col end)
      assert cols == [10, 2]
    end

    test "skips unsupported documentChanges kinds (CreateFile, etc.)" do
      edit = %{
        "documentChanges" => [
          %{"kind" => "create", "uri" => "file:///project/new.ex"},
          %{
            "textDocument" => %{"uri" => "file:///project/a.ex", "version" => 1},
            "edits" => [
              %{
                "range" => %{
                  "start" => %{"line" => 0, "character" => 0},
                  "end" => %{"line" => 0, "character" => 0}
                },
                "newText" => "hello"
              }
            ]
          }
        ]
      }

      result = WorkspaceEdit.parse(edit)
      assert length(result) == 1
      {path, _} = hd(result)
      assert String.ends_with?(path, "a.ex")
    end
  end

  describe "parse_text_edit/1" do
    test "parses a standard TextEdit" do
      te = %{
        "range" => %{
          "start" => %{"line" => 3, "character" => 7},
          "end" => %{"line" => 3, "character" => 12}
        },
        "newText" => "replacement"
      }

      assert {{3, 7}, {3, 12}, "replacement"} = WorkspaceEdit.parse_text_edit(te)
    end

    test "handles missing newText as empty string" do
      te = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 1, "character" => 0}
        }
      }

      assert {{0, 0}, {1, 0}, ""} = WorkspaceEdit.parse_text_edit(te)
    end
  end
end
