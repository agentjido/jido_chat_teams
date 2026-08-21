defmodule Jido.Chat.Teams.CardRendererTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Card
  alias Jido.Chat.Teams.CardRenderer

  test "renders canonical card parts as Adaptive Card elements" do
    card =
      Card.new(%{
        title: "Deploy",
        summary: "Release 42",
        components: [
          Card.field("State", "Ready"),
          Card.actions([
            Card.button("Approve", "approve", value: "42"),
            Card.link_button("Open", "https://example.test/release/42", action_id: "release:open")
          ])
        ]
      })

    rendered = CardRenderer.render(card)

    assert rendered["type"] == "AdaptiveCard"
    assert rendered["version"] == "1.5"
    assert Enum.any?(rendered["body"], &match?(%{"type" => "FactSet"}, &1))

    assert Enum.any?(rendered["body"], fn
             %{"type" => "ActionSet", "actions" => actions} ->
               Enum.any?(actions, &(&1["type"] == "Action.Submit")) and
                 Enum.any?(actions, &(&1["type"] == "Action.OpenUrl"))

             _other ->
               false
           end)

    open_action =
      rendered["body"]
      |> Enum.find_value(fn
        %{"type" => "ActionSet", "actions" => actions} ->
          Enum.find(actions, &(&1["type"] == "Action.OpenUrl"))

        _other ->
          nil
      end)

    assert open_action["id"] == "release:open"
  end

  test "renders Teams charts and uses text for unsupported area charts" do
    card =
      Card.new(%{
        components: [
          Card.pie_chart([{"Ready", 3}], title: "Status"),
          Card.bar_chart([{"Jan", 10}, {"Feb", 12}], title: "Requests"),
          Card.line_chart(
            ["Jan", "Feb"],
            [%{name: "API", values: [10, 12]}],
            title: "Trend"
          ),
          Card.area_chart([{"Jan", 10}], title: "Capacity")
        ]
      })

    body = CardRenderer.render(card)["body"]

    assert Enum.any?(body, &match?(%{"type" => "Chart.Pie"}, &1))
    assert Enum.any?(body, &match?(%{"type" => "Chart.VerticalBar"}, &1))

    assert Enum.any?(body, fn
             %{"type" => "Chart.Line", "data" => [series]} ->
               series["legend"] == "API" and
                 series["values"] == [%{"x" => "Jan", "y" => 10}, %{"x" => "Feb", "y" => 12}]

             _other ->
               false
           end)

    assert Enum.any?(body, fn
             %{"type" => "TextBlock", "text" => text} ->
               text =~ "Area chart" and text =~ "Jan: 10"

             _other ->
               false
           end)
  end

  test "renders a captioned first table page as an Adaptive Card table" do
    card =
      Card.new(%{
        components: [
          Card.table(
            ["Service", "State"],
            [["api", "ok"], ["worker", "ok"], ["web", "warn"]],
            caption: "Service health",
            page_size: 2
          )
        ]
      })

    assert [caption, table, page_note] = CardRenderer.render(card)["body"]

    assert caption == %{
             "type" => "TextBlock",
             "text" => "Service health",
             "wrap" => true,
             "weight" => "Bolder"
           }

    assert table["type"] == "Table"
    assert length(table["rows"]) == 3
    assert table["firstRowAsHeader"]
    assert page_note["text"] == "Showing 2 of 3 rows."
  end

  test "renders external selects with Teams data queries and enforces the Teams option limit" do
    select =
      Card.external_select("assignee",
        label: "Assignee",
        value: "user:ada",
        min_query_length: 2,
        options: [Card.select_option("Ada", "user:ada")]
      )

    assert [rendered] = CardRenderer.render(Card.new(%{components: [select]}))["body"]
    assert rendered["type"] == "Input.ChoiceSet"
    assert rendered["id"] == "assignee"
    assert rendered["style"] == "filtered"
    assert rendered["choices.data"] == %{"type" => "Data.Query", "dataset" => "assignee"}
    assert rendered["value"] == "user:ada"

    too_many =
      for index <- 1..16 do
        Card.select_option("Option #{index}", "value:#{index}")
      end

    oversized = Card.external_select("oversized", label: "Oversized", options: too_many)

    assert [%{"type" => "TextBlock", "text" => fallback}] =
             CardRenderer.render(Card.new(%{components: [oversized]}))["body"]

    assert fallback =~ "Oversized"
    assert fallback =~ "Teams supports at most 15 choices"
  end

  test "passes a raw Adaptive Card through" do
    card = %{"type" => "AdaptiveCard", "version" => "1.4", "body" => []}
    assert CardRenderer.render(card) == card
  end
end
