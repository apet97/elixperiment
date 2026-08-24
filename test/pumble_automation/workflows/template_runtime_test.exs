defmodule PumbleAutomation.Workflows.TemplateRuntimeTest do
  @moduledoc """
  Compiler-produced templates render against a JSON tree, or fail with a
  stable code. Nothing re-parses template text at run time.
  """

  use ExUnit.Case, async: true

  import PumbleAutomation.WorkflowsFixtures

  alias PumbleAutomation.Error
  alias PumbleAutomation.Workflows.Compiler
  alias PumbleAutomation.Workflows.Limits
  alias PumbleAutomation.Workflows.Node
  alias PumbleAutomation.Workflows.Templates

  @node_id "6f1b3c1e-1f2a-4c3d-8e4f-5a6b7c8d9e0f"

  describe "string rendering" do
    test "a plain string is the value, with no paths used" do
      assert Templates.render("hello", %{}) == {:ok, %{value: "hello", used_paths: []}}
    end

    test "a plain string is not scanned for references" do
      tree = %{"trigger" => %{"x" => "no"}}

      assert Templates.render("keep {{ trigger.x }}", tree) ==
               {:ok, %{value: "keep {{ trigger.x }}", used_paths: []}}
    end

    test "literals and references keep their order" do
      template = %{
        "template" => [
          %{"literal" => "A "},
          %{"path" => %{"root" => "trigger", "path" => ["name"]}},
          %{"literal" => " B"}
        ]
      }

      assert Templates.render(template, %{"trigger" => %{"name" => "Ada"}}) ==
               {:ok, %{value: "A Ada B", used_paths: ["trigger.name"]}}
    end

    test "a single string reference is the string itself" do
      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["text"]}}]}

      assert Templates.render(template, %{"trigger" => %{"text" => "hi"}}) ==
               {:ok, %{value: "hi", used_paths: ["trigger.text"]}}
    end

    test "numbers, booleans, and null convert without a locale" do
      tree = %{
        "trigger" => %{"n" => 42, "r" => 1.5, "ok" => true, "off" => false, "none" => nil}
      }

      assert render_path(["n"], tree) == {:ok, %{value: "42", used_paths: ["trigger.n"]}}
      assert render_path(["r"], tree) == {:ok, %{value: "1.5", used_paths: ["trigger.r"]}}
      assert render_path(["ok"], tree) == {:ok, %{value: "true", used_paths: ["trigger.ok"]}}
      assert render_path(["off"], tree) == {:ok, %{value: "false", used_paths: ["trigger.off"]}}
      assert render_path(["none"], tree) == {:ok, %{value: "null", used_paths: ["trigger.none"]}}
    end

    test "a compiler-produced template renders without re-parsing" do
      node =
        Node.new(:pumble_action, %{
          action: :send_message,
          channel_id: "channel-1",
          text: "hi {{ trigger.data.text }}"
        })

      assert {:ok, compiled} = Compiler.compile(definition([node]))
      template = compiled.nodes[node.id].config["text"]
      tree = %{"trigger" => %{"data" => %{"text" => "there"}}}

      assert Templates.render(template, tree) ==
               {:ok, %{value: "hi there", used_paths: ["trigger.data.text"]}}
    end

    test "a step output path includes the output segment in used_paths" do
      template = %{
        "template" => [
          %{
            "path" => %{
              "root" => "steps",
              "node_id" => @node_id,
              "path" => ["ticket_id"]
            }
          }
        ]
      }

      tree = %{"steps" => %{@node_id => %{"output" => %{"ticket_id" => "T-1"}}}}

      assert Templates.render(template, tree) ==
               {:ok, %{value: "T-1", used_paths: ["steps.#{@node_id}.output.ticket_id"]}}
    end
  end

  describe "JSON rendering" do
    test "a single reference in a JSON field is the native value" do
      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["payload"]}}]}
      payload = %{"id" => 7, "ok" => true}
      tree = %{"trigger" => %{"payload" => payload}}

      assert Templates.render(template, tree, insert: :json) ==
               {:ok, %{value: payload, used_paths: ["trigger.payload"]}}
    end

    test "a JSON field that is a string stays a string, not a quoted encoding" do
      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["text"]}}]}

      assert Templates.render(template, %{"trigger" => %{"text" => "hi"}}, insert: :json) ==
               {:ok, %{value: "hi", used_paths: ["trigger.text"]}}
    end

    test "explicit JSON insertion splices canonical JSON into surrounding text" do
      template = %{
        "template" => [
          %{"literal" => "data:"},
          %{"json" => %{"root" => "trigger", "path" => ["payload"]}}
        ]
      }

      tree = %{"trigger" => %{"payload" => %{"b" => 1, "a" => 2}}}

      assert Templates.render(template, tree) ==
               {:ok, %{value: ~s(data:{"a":2,"b":1}), used_paths: ["trigger.payload"]}}
    end

    test "a JSON field mixed with literals encodes each interpolation" do
      template = %{
        "template" => [
          %{"literal" => ~s({"n":)},
          %{"path" => %{"root" => "trigger", "path" => ["n"]}},
          %{"literal" => "}"}
        ]
      }

      assert Templates.render(template, %{"trigger" => %{"n" => 3}}, insert: :json) ==
               {:ok, %{value: ~s({"n":3}), used_paths: ["trigger.n"]}}
    end
  end

  describe "escaping" do
    test "quotes and backslashes in a string field are not rewritten" do
      text = ~s(say "hi" \\ please)
      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["text"]}}]}

      assert Templates.render(template, %{"trigger" => %{"text" => text}}) ==
               {:ok, %{value: text, used_paths: ["trigger.text"]}}
    end

    test "JSON insertion escapes quotes, backslashes, and control characters" do
      template = %{
        "template" => [
          %{"literal" => ~s({"msg":)},
          %{"json" => %{"root" => "trigger", "path" => ["text"]}},
          %{"literal" => "}"}
        ]
      }

      tree = %{"trigger" => %{"text" => "say \"hi\"\n"}}

      assert {:ok, %{value: json, used_paths: ["trigger.text"]}} =
               Templates.render(template, tree)

      assert json == ~s({"msg":"say \\"hi\\"\\n"})
      assert {:ok, _} = Jason.decode(json)
    end

    test "a resolved value is never scanned as a nested template" do
      template = %{
        "template" => [
          %{"literal" => "x="},
          %{"path" => %{"root" => "trigger", "path" => ["text"]}}
        ]
      }

      tree = %{"trigger" => %{"text" => "{{ trigger.other }}", "other" => "leaked"}}

      assert Templates.render(template, tree) ==
               {:ok, %{value: "x={{ trigger.other }}", used_paths: ["trigger.text"]}}
    end
  end

  describe "missing and null" do
    test "a present null is a value" do
      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["text"]}}]}
      tree = %{"trigger" => %{"text" => nil}}

      assert Templates.render(template, tree) ==
               {:ok, %{value: "null", used_paths: ["trigger.text"]}}

      assert Templates.render(template, tree, insert: :json) ==
               {:ok, %{value: nil, used_paths: ["trigger.text"]}}
    end

    test "an absent key fails by default" do
      template = %{"template" => [%{"path" => %{"root" => "trigger", "path" => ["text"]}}]}
      tree = %{"trigger" => %{}}

      assert {:error,
              %Error{class: :validation, code: :path_missing, details: %{path: "trigger.text"}}} =
               Templates.render(template, tree)
    end

    test "on_missing empty inserts an empty string when the caller permits it" do
      template = %{"template" => [%{"literal" => "x="}, %{"path" => path("text")}]}
      tree = %{"trigger" => %{}}

      assert Templates.render(template, tree, on_missing: :empty) ==
               {:ok, %{value: "x=", used_paths: ["trigger.text"]}}
    end

    test "on_missing null inserts null when the caller permits it" do
      template = %{"template" => [%{"path" => path("text")}]}
      tree = %{"trigger" => %{}}

      assert Templates.render(template, tree, on_missing: :null) ==
               {:ok, %{value: "null", used_paths: ["trigger.text"]}}

      assert Templates.render(template, tree, on_missing: :null, insert: :json) ==
               {:ok, %{value: nil, used_paths: ["trigger.text"]}}
    end
  end

  describe "non-string insertion" do
    test "an array in a string field requires explicit JSON insertion" do
      template = %{"template" => [%{"path" => path("items")}]}
      tree = %{"trigger" => %{"items" => [1, 2]}}

      assert {:error, %Error{code: :template_json_required, details: %{path: "trigger.items"}}} =
               Templates.render(template, tree)
    end

    test "an object in a string field requires explicit JSON insertion" do
      template = %{
        "template" => [%{"literal" => "x="}, %{"path" => path("obj")}]
      }

      tree = %{"trigger" => %{"obj" => %{"a" => 1}}}

      assert {:error, %Error{code: :template_json_required}} = Templates.render(template, tree)
    end

    test "explicit JSON insertion of an array is canonical JSON text" do
      template = %{"template" => [%{"json" => path("items")}]}
      tree = %{"trigger" => %{"items" => [1, 2]}}

      assert Templates.render(template, tree) ==
               {:ok, %{value: [1, 2], used_paths: ["trigger.items"]}}

      mixed = %{"template" => [%{"literal" => "n="}, %{"json" => path("items")}]}

      assert Templates.render(mixed, tree) ==
               {:ok, %{value: "n=[1,2]", used_paths: ["trigger.items"]}}
    end
  end

  describe "large expansion" do
    test "source at the limit is accepted" do
      text = String.duplicate("a", Limits.max_template_source())

      assert {:ok, %{value: ^text, used_paths: []}} = Templates.render(text, %{})
    end

    test "source one byte over the limit is refused" do
      text = String.duplicate("a", Limits.max_template_source() + 1)

      assert {:error, %Error{code: :template_too_large}} = Templates.render(text, %{})
    end

    test "a value at the per-value limit is accepted" do
      text = String.duplicate("v", Limits.max_template_value())
      template = %{"template" => [%{"path" => path("text")}]}

      assert {:ok, %{value: ^text}} =
               Templates.render(template, %{"trigger" => %{"text" => text}})
    end

    test "a value one byte over the per-value limit is refused" do
      text = String.duplicate("v", Limits.max_template_value() + 1)
      template = %{"template" => [%{"path" => path("text")}]}

      assert {:error, %Error{code: :template_value_too_large, details: details}} =
               Templates.render(template, %{"trigger" => %{"text" => text}})

      assert details.limit == Limits.max_template_value()
      assert details.actual == Limits.max_template_value() + 1
      refute inspect(details) =~ "vvv"
    end

    test "references at the limit are accepted" do
      template = %{
        "template" => List.duplicate(%{"path" => path("n")}, Limits.max_template_references())
      }

      assert {:ok, %{value: value}} = Templates.render(template, %{"trigger" => %{"n" => "x"}})
      assert value == String.duplicate("x", Limits.max_template_references())
    end

    test "one reference over the limit is refused before interpolation" do
      template =
        %{
          "template" =>
            List.duplicate(%{"path" => path("n")}, Limits.max_template_references() + 1)
        }

      assert {:error, %Error{code: :too_many_references}} =
               Templates.render(template, %{"trigger" => %{"n" => "x"}})
    end

    test "expansion at the limit is accepted and one extra byte is not" do
      chunk = String.duplicate("a", Limits.max_template_value())
      count = div(Limits.max_template_expansion(), Limits.max_template_value())
      template = %{"template" => List.duplicate(%{"path" => path("text")}, count)}
      tree = %{"trigger" => %{"text" => chunk}}

      assert {:ok, %{value: value}} = Templates.render(template, tree)
      assert byte_size(value) == Limits.max_template_expansion()

      over = %{
        "template" => [%{"literal" => "x"} | List.duplicate(%{"path" => path("text")}, count)]
      }

      assert {:error, %Error{code: :template_expansion_too_large}} = Templates.render(over, tree)
    end
  end

  describe "determinism" do
    test "the same template and tree produce the same bytes" do
      template = %{
        "template" => [
          %{"literal" => "hi "},
          %{"path" => path("text")}
        ]
      }

      tree = %{"trigger" => %{"text" => "Ada"}}

      assert Templates.render(template, tree) == Templates.render(template, tree)
    end

    test "JSON object insertion is independent of map key insertion order" do
      template = %{"template" => [%{"json" => path("obj")}]}
      left = %{"trigger" => %{"obj" => Map.put(%{"b" => 1}, "a", 2)}}
      right = %{"trigger" => %{"obj" => Map.put(%{"a" => 2}, "b", 1)}}

      mixed = %{"template" => [%{"literal" => ""}, %{"json" => path("obj")}]}

      assert Templates.render(mixed, left) == Templates.render(mixed, right)

      assert Templates.render(template, left, insert: :json) ==
               Templates.render(template, right, insert: :json)
    end

    test "a date-shaped string is not formatted as a timestamp" do
      template = %{"template" => [%{"path" => path("when")}]}
      text = "2026-08-18T00:00:00Z"

      assert Templates.render(template, %{"trigger" => %{"when" => text}}) ==
               {:ok, %{value: text, used_paths: ["trigger.when"]}}
    end
  end

  describe "secrets" do
    test "a secret stays a write-only placeholder and is named without a value" do
      template = %{
        "template" => [
          %{"literal" => "token="},
          %{"path" => %{"root" => "secret", "name" => "API_TOKEN"}}
        ]
      }

      planted = "s3cret-value"
      tree = %{"trigger" => %{"text" => planted}}

      assert {:ok, %{value: value, used_paths: ["secret.API_TOKEN"]}} =
               Templates.render(template, tree)

      assert value == "token=" <> Templates.secret_placeholder("API_TOKEN")
      refute String.contains?(value, planted)
      refute String.contains?(inspect(value), planted)
    end

    test "a JSON field that is only a secret is a handle, not a value" do
      template = %{"template" => [%{"path" => %{"root" => "secret", "name" => "API_TOKEN"}}]}

      assert Templates.render(template, %{}, insert: :json) ==
               {:ok, %{value: %{"secret" => "API_TOKEN"}, used_paths: ["secret.API_TOKEN"]}}
    end
  end

  describe "refusals" do
    test "a value that is not a compiled template is refused" do
      assert {:error, %Error{code: :invalid_template}} = Templates.render(nil, %{})
      assert {:error, %Error{code: :invalid_template}} = Templates.render(%{}, %{})

      assert {:error, %Error{code: :invalid_template}} =
               Templates.render([%{"path" => path("x")}], %{})
    end

    test "a malformed segment is refused" do
      template = %{"template" => [%{"nope" => true}]}

      assert {:error, %Error{code: :invalid_template}} = Templates.render(template, %{})
    end

    test "path type errors pass through" do
      template = %{
        "template" => [%{"path" => %{"root" => "trigger", "path" => ["data", "text"]}}]
      }

      tree = %{"trigger" => %{"data" => nil}}

      assert {:error, %Error{code: :path_type_mismatch, details: %{path: "trigger.data.text"}}} =
               Templates.render(template, tree)
    end

    test "errors name the path and never interpolate a value" do
      template = %{"template" => [%{"path" => path("missing")}]}
      tree = %{"trigger" => %{"text" => "classified"}}

      assert {:error, %Error{message: message, details: details}} =
               Templates.render(template, tree)

      refute String.contains?(message, "classified")
      refute details |> inspect() |> String.contains?("classified")
    end

    test "an unknown option value is refused" do
      assert {:error, %Error{code: :invalid_template}} =
               Templates.render("x", %{}, on_missing: :skip)

      assert {:error, %Error{code: :invalid_template}} =
               Templates.render("x", %{}, insert: :html)
    end
  end

  describe "used paths" do
    test "every interpolation is listed, in order, without values" do
      template = %{
        "template" => [
          %{"path" => path("a")},
          %{"literal" => "-"},
          %{"path" => path("b")},
          %{"path" => path("a")}
        ]
      }

      tree = %{"trigger" => %{"a" => "secret-ish", "b" => "other"}}

      assert {:ok, %{value: "secret-ish-othersecret-ish", used_paths: used}} =
               Templates.render(template, tree)

      assert used == ["trigger.a", "trigger.b", "trigger.a"]
    end
  end

  defp render_path(segments, tree) do
    Templates.render(
      %{"template" => [%{"path" => %{"root" => "trigger", "path" => segments}}]},
      tree
    )
  end

  defp path(name), do: %{"root" => "trigger", "path" => [name]}
end
