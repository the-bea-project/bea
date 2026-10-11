import gleam/bool

pub fn calculate_score(points, bonus) {
  let total = points + bonus
  use <- bool.guard(when: total > 100, return: "high_score")
  "try_again"
}