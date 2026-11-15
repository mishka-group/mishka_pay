# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_pay/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# Mishka Pay's own DSL entities, written without parentheses here and in a project that imports
# this formatter. Empty until the Ash layer adds `pay do ... end`.
spark_locals_without_parens = []

[
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens],
  import_deps: [:ash, :spark, :guarded_struct],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
