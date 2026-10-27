//// Names that exist only in the generated Gleam, which the language server
//// keeps out of completions; names users write are never among them.

import bea/codegen

pub fn lowering_variables_are_generated_test() {
  assert codegen.generated_name("bea_try_12")
  assert codegen.generated_name("bea_value_40")
  assert codegen.generated_name("bea_continue_7")
}

pub fn helper_aliases_are_generated_test() {
  assert codegen.generated_name("bea_bool_guard")
  assert codegen.generated_name("bea_result_try")
  assert codegen.generated_name("bea_bool")
}

pub fn names_users_write_are_not_test() {
  assert !codegen.generated_name("bea_codecs/json/encoder")
  assert !codegen.generated_name("bea_codecs")
  assert !codegen.generated_name("bea_count")
  assert !codegen.generated_name("bea_try_")
  assert !codegen.generated_name("bea_try_x")
  assert !codegen.generated_name("encoder")
}
