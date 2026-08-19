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
            Card.link_button("Open", "https://example.test/release/42")
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
  end

  test "passes a raw Adaptive Card through" do
    card = %{"type" => "AdaptiveCard", "version" => "1.4", "body" => []}
    assert CardRenderer.render(card) == card
  end
end
