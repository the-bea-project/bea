import gleam/bool

pub fn calculate_score(points, bonus) {
  let total = points + bonus
  use <- bool.guard(when: total > 100, return: "high_score")
  use <- bool.guard(when: total != 1, return: "something")
  "try_again"
}