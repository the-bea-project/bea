//// Bidirectional position mapping between a Bea module and the Gleam code
//// generated for it, built from the marks recorded by `bea/doc`.

import bea/doc.{type Mapping}
import bea/span.{type LineIndex, type Span, Span}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order

pub type SourceMap {
  SourceMap(
    mappings: List(Mapping),
    bea: LineIndex,
    gleam: LineIndex,
    bea_source: String,
    gleam_source: String,
  )
}

pub fn new(
  mappings: List(Mapping),
  bea_source: String,
  gleam_source: String,
) -> SourceMap {
  SourceMap(
    mappings: list.filter(mappings, fn(m) {
      m.source != span.empty && m.generated.end > m.generated.start
    }),
    bea: span.line_index(bea_source),
    gleam: span.line_index(gleam_source),
    bea_source: bea_source,
    gleam_source: gleam_source,
  )
}

fn smallest(
  candidates: List(Mapping),
  size: fn(Mapping) -> Int,
) -> Option(Mapping) {
  list.fold(candidates, None, fn(best, m) {
    case best {
      None -> Some(m)
      Some(b) ->
        case size(m) < size(b) {
          True -> Some(m)
          False -> best
        }
    }
  })
}

fn gen_len(m: Mapping) -> Int {
  m.generated.end - m.generated.start
}

fn src_len(m: Mapping) -> Int {
  m.source.end - m.source.start
}

/// Translate a byte offset in the generated Gleam to the Bea source.
pub fn to_bea_offset(map: SourceMap, offset: Int) -> Option(Int) {
  map.mappings
  |> list.filter(fn(m) {
    offset >= m.generated.start && offset < m.generated.end
  })
  |> smallest(gen_len)
  |> option.map(fn(m) {
    m.source.start + int.clamp(offset - m.generated.start, 0, src_len(m))
  })
}

/// Translate a byte offset in the Bea source to the generated Gleam.
pub fn to_gleam_offset(map: SourceMap, offset: Int) -> Option(Int) {
  map.mappings
  |> list.filter(fn(m) { offset >= m.source.start && offset < m.source.end })
  |> smallest(src_len)
  |> option.map(fn(m) {
    m.generated.start + int.clamp(offset - m.source.start, 0, gen_len(m))
  })
}

/// Translate a span of generated Gleam to the best matching Bea span.
pub fn to_bea_span(map: SourceMap, generated: Span) -> Option(Span) {
  let containing =
    map.mappings
    |> list.filter(fn(m) {
      generated.start >= m.generated.start && generated.end <= m.generated.end
    })
  case smallest(containing, gen_len) {
    None ->
      to_bea_offset(map, generated.start)
      |> option.map(fn(o) { Span(o, o + 1) })
    Some(m) ->
      case m.generated == generated || gen_len(m) != src_len(m) {
        True -> Some(m.source)
        False -> {
          let start = m.source.start + { generated.start - m.generated.start }
          Some(Span(start, start + { generated.end - generated.start }))
        }
      }
  }
}

/// Translate a span of Bea source to the generated Gleam.
pub fn to_gleam_span(map: SourceMap, source: Span) -> Option(Span) {
  let containing =
    map.mappings
    |> list.filter(fn(m) {
      source.start >= m.source.start && source.end <= m.source.end
    })
  case smallest(containing, src_len) {
    None -> None
    Some(m) ->
      case m.source == source || gen_len(m) != src_len(m) {
        True -> Some(m.generated)
        False -> {
          let start = m.generated.start + { source.start - m.source.start }
          Some(Span(start, start + { source.end - source.start }))
        }
      }
  }
}

/// Which Bea line (zero based) does a generated line come from?
pub fn bea_line_for_gleam_line(map: SourceMap, line: Int) -> Option(Int) {
  let start = span.line_start(map.gleam, line)
  let end = span.line_end(map.gleam, line)
  // Prefer the innermost mapping that starts on this line.
  let starting =
    list.filter(map.mappings, fn(m) {
      m.generated.start >= start && m.generated.start <= end
    })
  let candidate = case starting {
    [] ->
      list.filter(map.mappings, fn(m) {
        start >= m.generated.start && start < m.generated.end
      })
      |> smallest(gen_len)
    _ ->
      // The earliest starting mapping on the line, innermost if tied.
      list.fold(starting, None, fn(best: Option(Mapping), m: Mapping) {
        case best {
          None -> Some(m)
          Some(b) ->
            case
              m.generated.start < b.generated.start
              || {
                m.generated.start == b.generated.start
                && gen_len(m) > gen_len(b)
              }
            {
              True -> Some(m)
              False -> best
            }
        }
      })
  }
  option.map(candidate, fn(m) { span.position(map.bea, m.source.start).line })
}

/// Like `to_gleam_offset`, but an offset just after the end of a node (where
/// an editor cursor sits after typing a name) also maps.
///
/// A node that ends at the cursor wins over a bigger node around it: inside
/// `if c { return la| }` the cursor is also "inside" the `if` (lowered to a
/// `bool.guard(...)` of a different length), and mapping the offset linearly
/// through that would land on the wrong Gleam token.
pub fn to_gleam_offset_inclusive(map: SourceMap, offset: Int) -> Option(Int) {
  inclusive(map, offset, False)
}

/// For completion: when one node ends at the cursor and another starts there
/// (`la|.x`), the one being typed (before the cursor) wins.
pub fn to_gleam_offset_after(map: SourceMap, offset: Int) -> Option(Int) {
  inclusive(map, offset, True)
}

fn inclusive(map: SourceMap, offset: Int, prefer_before: Bool) -> Option(Int) {
  let containing =
    map.mappings
    |> list.filter(fn(m) { offset >= m.source.start && offset < m.source.end })
    |> innermost
  let ending =
    map.mappings
    |> list.filter(fn(m) { offset == m.source.end && offset > m.source.start })
    |> innermost
  let linear = fn(m: Mapping) {
    m.generated.start + int.clamp(offset - m.source.start, 0, gen_len(m))
  }
  case containing, ending {
    None, None -> None
    Some(c), None -> Some(linear(c))
    None, Some(e) -> Some(e.generated.end)
    Some(c), Some(e) ->
      // `e` nested in `c`: the cursor is right after `e`, in `c`'s gap text.
      case c.source.start <= e.source.start || prefer_before {
        True -> Some(e.generated.end)
        False -> Some(linear(c))
      }
  }
}

/// The smallest mapping (by source length, then generated length).
fn innermost(candidates: List(Mapping)) -> Option(Mapping) {
  list.fold(candidates, None, fn(best, m) {
    case best {
      None -> Some(m)
      Some(b) ->
        case int.compare(src_len(m), src_len(b)) {
          order.Lt -> Some(m)
          order.Eq ->
            case gen_len(m) < gen_len(b) {
              True -> Some(m)
              False -> best
            }
          order.Gt -> best
        }
    }
  })
}
