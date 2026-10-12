pub fn fib(arg_0) {
  case arg_0 {
    0 -> {
      0
    }
    1 -> {
      1
    }
    n -> {
      fib(n - 1) + fib(n - 2)
    }
  }
}
