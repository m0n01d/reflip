// Unit tests for Stats.compute: a known array, one value, an empty list.

let run = () => {
  TestKit.section("Stats.compute")

  switch Stats.compute([10.0, 20.0, 30.0, 40.0, 50.0]) {
  | Some(s) => {
      TestKit.check("count", s.count == 5)
      TestKit.approx("min", s.minUsd, 10.0, ~eps=1e-9)
      TestKit.approx("p25", s.p25Usd, 20.0, ~eps=1e-9)
      TestKit.approx("median", s.medianUsd, 30.0, ~eps=1e-9)
      TestKit.approx("p75", s.p75Usd, 40.0, ~eps=1e-9)
      TestKit.approx("max", s.maxUsd, 50.0, ~eps=1e-9)
    }
  | None => TestKit.check("known array returned Some", false)
  }

  switch Stats.compute([42.0]) {
  | Some(s) => {
      TestKit.check("one value count", s.count == 1)
      TestKit.approx("one value min", s.minUsd, 42.0, ~eps=1e-9)
      TestKit.approx("one value p25", s.p25Usd, 42.0, ~eps=1e-9)
      TestKit.approx("one value median", s.medianUsd, 42.0, ~eps=1e-9)
      TestKit.approx("one value p75", s.p75Usd, 42.0, ~eps=1e-9)
      TestKit.approx("one value max", s.maxUsd, 42.0, ~eps=1e-9)
    }
  | None => TestKit.check("one value returned Some", false)
  }

  TestKit.check("empty list is None", Stats.compute([]) == None)

  switch Stats.compute([30.0, 10.0, 50.0, 20.0, 40.0]) {
  | Some(s) => TestKit.approx("unsorted input still sorts", s.medianUsd, 30.0, ~eps=1e-9)
  | None => TestKit.check("unsorted input returned Some", false)
  }
}
