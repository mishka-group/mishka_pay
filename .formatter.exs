# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Mishka Pay's own DSL (`mishka_pay do ... end` of `MishkaPay.Ash.Resource`), written without
# parentheses here and in a project that imports this formatter.
spark_locals_without_parens = [
  actions: 1,
  announce?: 1,
  belongs_to_user: 1,
  tenant_from: 1,
  code_interface?: 1,
  kind: 1,
  listen?: 1
]

[
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens],
  import_deps: [:ash, :ash_oban, :ash_postgres, :spark, :guarded_struct],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
