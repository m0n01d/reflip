// Price statistics over an array of USD prices: count, min, p25, median,
// p75, max. Linear-interpolation percentiles. `compute` returns `None` for
// an empty array — there is nothing to summarize.

let percentile = (sorted: array<float>, p: float): float =>
  if Array.length(sorted) <= 1 {
    Array.get(sorted, 0)->Option.getOr(0.0)
  } else {
    let n = Array.length(sorted)
    let idx = p *. Int.toFloat(n - 1)
    let lo = Float.toInt(Math.floor(idx))
    let hiRaw = lo + 1
    let hi = hiRaw > n - 1 ? n - 1 : hiRaw
    let frac = idx -. Int.toFloat(lo)
    let loVal = Array.get(sorted, lo)->Option.getOr(0.0)
    let hiVal = Array.get(sorted, hi)->Option.getOr(0.0)
    loVal *. (1.0 -. frac) +. hiVal *. frac
  }

let compute = (prices: array<float>): option<Types.ebayStats> => {
  let n = Array.length(prices)
  if n == 0 {
    None
  } else {
    let sorted = Array.toSorted(prices, (a, b) => Float.compare(a, b))
    Some({
      Types.count: n,
      minUsd: Array.get(sorted, 0)->Option.getOr(0.0),
      p25Usd: percentile(sorted, 0.25),
      medianUsd: percentile(sorted, 0.5),
      p75Usd: percentile(sorted, 0.75),
      maxUsd: Array.get(sorted, n - 1)->Option.getOr(0.0),
    })
  }
}
