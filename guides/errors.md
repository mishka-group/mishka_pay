# Errors

> On the web, with more detail: [Errors and telemetry](https://mishka.tools/pay/docs/errors-and-telemetry).

Every call answers `{:ok, struct}` or `{:error, error}`, where `error` is a `MishkaPay.Errors`
(Splode) exception. Show people `MishkaPay.Ash.message(error)` (with Ash) or
`Exception.message(error)`: plain sentences that never repeat a provider's own words, which can
name keys and ids.

| Error | Means | Do |
|---|---|---|
| `MishkaPay.Errors.Invalid` | bad input; `errors` has each field | show it on the field |
| `MishkaPay.Errors.Declined` | the card or buyer was declined (`reason`) | ask for another way to pay |
| `MishkaPay.Errors.Rejected` | the provider refused (`status`, `code`, `param`) | log it; often keys or ids |
| `MishkaPay.Errors.Refused` | your checkout gate said no | show its reason |
| `MishkaPay.Errors.Unsupported` | the provider cannot do it | pick another provider |
| `MishkaPay.Errors.MissingCredentials` | no keys for that provider and site | the site adds keys |
| `MishkaPay.Errors.UnknownProvider` | no such provider installed | supervise it |
| `MishkaPay.Errors.Unreachable` | no answer from the provider | try later; nothing was charged twice |

`Rejected` codes Mishka Pay names itself: `"idempotency_error"` (a reference reused with other
details), `"already_exists"`, `"resource_missing"`, `"managed_payments_invoice"`. Its `param` is
the refused field, by Mishka Pay's name when it has one (`"trial_days"`).
