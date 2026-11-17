# Validation

The default suite does not call Microsoft. It checks:

- capability and unsupported-operation contracts;
- canonical results and explicit credential flow;
- message, update, delete, reaction, action, and option normalization;
- Bot Connector JWT admission;
- Activity Protocol request shape and error mapping;
- trusted service and media hosts;
- bounded media downloads and safe redirects;
- conversation references, cards, and modal rendering.

Run:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test.contracts
mix quality
mix coveralls
```

Live checks are separate and excluded by default. They require explicit test
tenant credentials and an encoded conversation reference.
