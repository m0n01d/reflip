// GET /api/hauls: one row per haul, newest first, with photo/gem counts
// and the buy list. Per docs/spec-haul-map.md "Shape" and MVP step 3.

let buyOf = (f: Store.find): option<Types.haulBuy> =>
  switch f.paidUsd {
  | Some(paidUsd) =>
    Some({
      Types.name: f.name,
      paidUsd,
      // finds has no paidOn column yet -- see Types.haulBuy's comment.
      paidOn: None,
      soldUsd: f.soldUsd,
      soldOn: f.soldOn,
    })
  | None => None
  }

// build sorts newest-first itself, by startedAt descending, with a stable
// sort so ties keep the order the caller gave them in. Store.listHauls
// already orders its query by startedAt DESC, rowid DESC, so a caller
// that passes that order through gets the rowid tiebreak for free; a
// caller (such as a test) that passes hauls in another order still gets
// a correct startedAt sort, just without a defined tiebreak among equal
// startedAt values beyond "stable" (the input order is kept).
let build = (
  ~hauls: array<Store.haul>,
  ~photoCounts: Dict.t<int>,
  ~finds: array<(string, Store.find)>,
  ~gemMinUsd: float,
): array<Types.haulListRow> =>
  hauls
  ->Array.toSorted((a, b) =>
    a.Store.startedAt < b.Store.startedAt ? 1.0 : a.Store.startedAt > b.Store.startedAt ? -1.0 : 0.0
  )
  ->Array.map(haul => {
    let haulFinds =
      finds->Array.filterMap(((haulId, find)) => haulId == haul.Store.haulId ? Some(find) : None)
    let gemCount = haulFinds->Array.filter(f => f.Store.estimateHighUsd >= gemMinUsd)->Array.length
    let buys = haulFinds->Array.filterMap(buyOf)
    let paidUsd = buys->Array.reduce(0.0, (acc, b) => acc +. b.Types.paidUsd)
    {
      Types.haulId: haul.haulId,
      name: haul.name,
      startedAt: haul.startedAt,
      place: haul.place,
      photoCount: Dict.get(photoCounts, haul.haulId)->Option.getOr(0),
      gemCount,
      paidUsd,
      buys,
    }
  })

let fromStore = (db: Store.t, config: Config.t): array<Types.haulListRow> =>
  build(
    ~hauls=Store.listHauls(db),
    ~photoCounts=Store.photoCountsOf(db),
    ~finds=Store.findsAll(db),
    ~gemMinUsd=config.haulGemMinUsd,
  )
