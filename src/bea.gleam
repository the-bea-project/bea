//// Entry point of the `bea` executable.

import argv
import bea/cli
import bea/system

pub fn main() -> Nil {
  system.init()
  let code = cli.main(argv.load().arguments)
  system.halt(code)
}
