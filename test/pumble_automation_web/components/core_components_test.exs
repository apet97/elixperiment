defmodule PumbleAutomationWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PumbleAutomationWeb.CoreComponents

  test "input describes persistent help without errors" do
    document = render_input(describedby: "request-help")

    assert LazyHTML.attribute(LazyHTML.query(document, "#request-field"), "aria-describedby") == [
             "request-help"
           ]
  end

  test "input keeps the existing error description without help" do
    document = render_input(errors: ["is invalid"])

    assert LazyHTML.attribute(LazyHTML.query(document, "#request-field"), "aria-describedby") == [
             "request-field-errors"
           ]
  end

  test "input describes both persistent help and current errors" do
    document = render_input(describedby: "request-help", errors: ["is invalid"])

    assert LazyHTML.attribute(LazyHTML.query(document, "#request-field"), "aria-describedby") == [
             "request-help request-field-errors"
           ]
  end

  defp render_input(attrs) do
    attrs =
      Keyword.merge(
        [id: "request-field", name: "request", label: "Request", value: "", type: "text"],
        attrs
      )

    render_component(&CoreComponents.input/1, Map.new(attrs))
    |> LazyHTML.from_fragment()
  end
end
