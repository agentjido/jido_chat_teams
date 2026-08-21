defmodule Jido.Chat.Teams.ModalRendererTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Modal
  alias Jido.Chat.Teams.ModalRenderer

  test "renders date, number, and external-select inputs as an Adaptive Card" do
    modal =
      Modal.new(%{
        callback_id: "report:create",
        title: "Create report",
        submit_label: "Create",
        elements: [
          Modal.date_input("day", "Day",
            value: "2026-08-20",
            min_date: "2026-01-01",
            max_date: "2026-12-31",
            required: true
          ),
          Modal.number_input("count", "Count", value: 12.5, min_value: 1, max_value: 100),
          Modal.external_select("owner", "Owner", min_query_length: 2)
        ]
      })

    rendered = ModalRenderer.render(modal)

    assert rendered["type"] == "AdaptiveCard"
    assert rendered["version"] == "1.5"

    assert Enum.any?(rendered["body"], fn
             %{"type" => "Input.Date"} = input ->
               input["id"] == "day" and input["value"] == "2026-08-20" and
                 input["min"] == "2026-01-01" and input["max"] == "2026-12-31" and
                 input["isRequired"]

             _other ->
               false
           end)

    assert Enum.any?(rendered["body"], fn
             %{"type" => "Input.Number"} = input ->
               input["id"] == "count" and input["value"] == 12.5 and input["min"] == 1 and
                 input["max"] == 100

             _other ->
               false
           end)

    assert Enum.any?(rendered["body"], fn
             %{"type" => "Input.ChoiceSet", "choices.data" => data} = input ->
               input["id"] == "owner" and input["style"] == "filtered" and
                 data == %{"type" => "Data.Query", "dataset" => "owner"}

             _other ->
               false
           end)

    assert [%{"type" => "Action.Submit", "data" => data}] = rendered["actions"]
    assert data == %{"action_id" => "report:create", "callback_id" => "report:create"}
  end

  test "returns deterministic text fallbacks for unsupported option groups and number steps" do
    with_group =
      Modal.external_select("owner", "Owner",
        option_groups: [
          Modal.select_option_group("Teams", [Modal.select_option("Core", "team:core")])
        ]
      )

    stepped = Modal.number_input("amount", "Amount", step: 0.5)

    rendered =
      ModalRenderer.render(Modal.new(%{title: "Fallbacks", elements: [with_group, stepped]}))

    assert Enum.any?(rendered["body"], fn
             %{"type" => "TextBlock", "text" => text} -> text =~ "Owner" and text =~ "Teams"
             _other -> false
           end)

    assert Enum.any?(rendered["body"], fn
             %{"type" => "TextBlock", "text" => text} -> text =~ "Amount" and text =~ "Step: 0.5"
             _other -> false
           end)
  end
end
