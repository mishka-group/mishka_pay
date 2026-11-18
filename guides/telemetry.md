# Telemetry

> On the web, with more detail: [Telemetry events](https://mishka.tools/pay/docs/errors-and-telemetry#telemetry-events).

Every event carries `:provider`; none carries a key or a buyer's details.

| Event | When | Metadata |
|---|---|---|
| `[:mishka_pay, operation, :start \| :stop]` | each call of `MishkaPay` (operation: `:checkout`, `:payment`, `:refund`, `:subscription_change`, `:dispute`...) | `:provider`, `:tenant`; on `:stop` the `:outcome` (`:ok` or the error's class) |
| `[:mishka_pay, :credentials, :start \| :stop]` | each keys lookup | `:provider`, `:tenant`; on `:stop` the `:outcome` (`:ok`, `:invalid`, or why there are no keys: `:no_answer`, `:cannot_run`, `:raised`, `:exited`, `:timeout`) |
| `[:mishka_pay, :request, :start \| :stop \| :exception]` | each HTTP request to a provider | `:provider`, `:method`, `:path`, `:idempotency_key`; `:status` on `:stop` |
| `[:mishka_pay, :request, :retry]` | before each retry | `:wait` in milliseconds, `:attempt`, the `:status` or network `:reason`, `:retry_after` |
| `[:mishka_pay, :inbox, :process, :start \| :stop]` | each try of the Ash inbox at one event | `:provider`, `:tenant`, `:type`, `:event_id`; on `:stop` the `:outcome` (`:processed` or `:retry`) and the measurement `:lag` (milliseconds since it was stored) |
| `[:mishka_pay, :inbox, :failed]` | an inbox event out of tries | `:provider`, `:tenant`, `:type`, `:event_id` |
| `[:mishka_pay, :webhook, :start \| :stop]` | each webhook | `:provider`; on `:stop` the `:status`, the `:outcome`, and for a checked event its `:tenant`, `:type` and `:id` (a tenant only once the signature proves it) |

Attach with `:telemetry.attach_many/4`; the demo shows them live.
