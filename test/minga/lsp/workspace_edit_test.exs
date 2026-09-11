defmodule Minga.LSP.WorkspaceEditTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.WorkspaceEdit

  describe "parse/1" do
    test "rejects nil" do
      assert WorkspaceEdit.parse(nil) == {:error, :invalid_workspace_edit}
    end

    test "rejects non-map input" do
      assert WorkspaceEdit.parse("not a map") == {:error, :invalid_workspace_edit}
      assert WorkspaceEdit.parse(42) == {:error, :invalid_workspace_edit}
    end

    test "distinguishes a valid empty edit" do
      assert WorkspaceEdit.parse(%{}) == {:ok, []}
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

      assert {:ok, [document]} = WorkspaceEdit.parse(edit)
      assert String.ends_with?(document.path, "lib/foo.ex")
      assert document.uri == "file:///home/user/project/lib/foo.ex"
      assert document.version == nil
      assert Enum.count(document.edits) == 2

      [first, second] = document.edits
      assert first["range"]["start"]["line"] == 5
      assert second["range"]["start"]["line"] == 2
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

      assert {:ok, documents} = WorkspaceEdit.parse(edit)
      assert Enum.count(documents) == 2
      paths = Enum.map(documents, & &1.path) |> Enum.sort()
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

      assert {:ok, [document]} = WorkspaceEdit.parse(edit)
      assert String.ends_with?(document.path, "lib/bar.ex")
      assert document.uri == "file:///project/lib/bar.ex"
      assert document.version == 1
      assert [edit] = document.edits
      assert edit["newText"] == "renamed"
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
      assert {:ok, [document]} = WorkspaceEdit.parse(edit)
      assert String.ends_with?(document.path, "a.ex")
    end

    test "preserves server edit order within a file" do
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

      assert {:ok, [document]} = WorkspaceEdit.parse(edit)
      lines = Enum.map(document.edits, & &1["range"]["start"]["line"])
      assert lines == [1, 10, 5]
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

      assert {:ok, [document]} = WorkspaceEdit.parse(edit)
      cols = Enum.map(document.edits, & &1["range"]["start"]["character"])
      assert cols == [10, 2]
    end

    test "rejects unsupported resource operations before returning documents" do
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

      assert WorkspaceEdit.parse(edit) == {:error, :unsupported_resource_operation}
    end
  end

  test "rejects a missing replacement instead of turning it into deletion" do
    workspace_edit = %{
      "changes" => %{
        "file:///project/a.ex" => [
          %{
            "range" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 1, "character" => 0}
            }
          }
        ]
      }
    }

    assert WorkspaceEdit.parse(workspace_edit) == {:error, :invalid_text_edit}
  end

  test "rejects malformed versions and positions" do
    malformed_version = %{
      "documentChanges" => [
        %{
          "textDocument" => %{"uri" => "file:///project/a.ex", "version" => "7"},
          "edits" => []
        }
      ]
    }

    malformed_position = %{
      "changes" => %{
        "file:///project/a.ex" => [
          %{
            "range" => %{
              "start" => %{"line" => -1, "character" => 0},
              "end" => %{"line" => 0, "character" => 0}
            },
            "newText" => "x"
          }
        ]
      }
    }

    assert WorkspaceEdit.parse(malformed_version) == {:error, :invalid_document_change}
    assert WorkspaceEdit.parse(malformed_position) == {:error, :invalid_text_edit}
  end
end
