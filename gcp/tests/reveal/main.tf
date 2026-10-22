# TEST HELPER, not part of the template. `terraform test` masks sensitive outputs, so a
# run of this module takes the connection code a previous run produced and prints it:
# tests/test_code_schema.py reads the codes from `terraform test -verbose` this way.
# The codes are built from the FAKE key files of tests/stack.tftest.hcl.

terraform {
  required_version = ">= 1.5.0"
}

variable "code" {
  type        = string
  sensitive   = true
  description = "symbol_connection_code of a previous run."
}

output "revealed_code" {
  description = "The code, printed by terraform test -verbose."
  value       = nonsensitive(var.code)
}
