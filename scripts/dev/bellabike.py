#!/usr/bin/env python3
# ===========================================================================
# bellabike.py — the ONE BellaBike read-only tool (catalog discovery, stock
# model, and validation). Source of truth = BellaBike Magento 2.4.7 store.
# Read-only: every call is a GET. Replaces bellabike.sh + bb-check/mismatch/
# salable/confirm.py.
#
#   export BB_TOKEN='…integration access token…'   # for admin/MSI commands
#
# COMMANDS
#   discovery (need token):
#     counts                         catalog sizes (all / visible / simple)
#     tree                           eBike category tree
#     raw [pageSize]                 FULL dump of cat-50 set -> bb-raw.jsonl
#                                    (NDJSON: line1 = meta+attr option dicts;
#                                     rest = full product objects)
#   offline analysis (no token, reads bb-raw.jsonl):
#     census                         tabulate the population -> bb-census.json
#   storefront cross-check (no token, public GraphQL):
#     check [N] [simples|children|mix]   E2E spot-check vs live storefront
#     mismatch                       hunt the salable_qty-vs-storefront gap
#     confirm                        two-sided proof the 0.6% is correctly
#                                    excluded (+DB side if BB_TOKEN set)
#   MSI / stock truth (need token):
#     gate [--full]                  RESOLVED buyable gate: is-product-salable/2
#                                    per parent(+simple); --full also per child
#     salable SKU [SKU...]           per-stock salable_qty + is_salable
#     sources SKU [SKU...]           per-source qty + stock/source topology
#     scope SKU [SKU...]             admin- vs store-view visibility/status
#     avail SKU                      raw availability fields for one SKU
#   orchestrator (need token):
#     validate                       census + gate + confirm — full health check
#
# THE RESOLVED MODEL (2026-06-04): online salability lives ONLY in website
# stock id 2. A SKU is buyable iff is-product-salable/{sku}/2 == true, applied
# at the PARENT for configurables (catalog membership) and per CHILD for size.
# `salable_qty` (the /products aggregate) over-counts; GraphQL is an optional
# cross-check, not a dependency. See `confirm`/`gate`.
# ===========================================================================
import json, os, re, sys, time, html, random, datetime, pathlib
import urllib.request, urllib.parse, urllib.error

HERE = pathlib.Path(__file__).resolve().parent
REST = "https://bellabike.ro/rest/V1"
GQL  = "https://bellabike.ro/graphql"
UA   = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
LEAVES   = ["721", "722", "723", "725", "751"]
CATSET   = "50,721,722,723,725,751"
WEBSITE_STOCK = "2"     # "Stock Bellabike" — the only sales channel that sells
SPEC_CODES = ["marime","marime_roata","color","manufacturer","producatori","material",
              "motorizare","numar_viteze","tip_franare","capacitate_baterie","putere_motor",
              "gen","model","disponibilitate_stocuri","zento_availability"]

def token():
    t = os.environ.get("BB_TOKEN")
    if not t:
        sys.exit("export BB_TOKEN first (run via:  ! BB_TOKEN='…' python3 bellabike.py <cmd>)")
    return t

# Cloudflare Access service token. The whole bellabike.ro zone is behind CF
# Access, so every request needs these (same values as Vault
# bike_bella_cf_access_id / bike_bella_cf_access_secret used by the edge fn).
# Optional: if unset, headers are omitted (works only from an allowlisted IP).
def cf_headers():
    cid = os.environ.get("BB_CF_ID")
    sec = os.environ.get("BB_CF_SECRET")
    return {"CF-Access-Client-Id": cid, "CF-Access-Client-Secret": sec} if cid and sec else {}

# ---- HTTP -----------------------------------------------------------------
def rest(path, base=REST):
    """GET REST; returns parsed JSON, or {'_error':...} on non-JSON/HTTP error."""
    req = urllib.request.Request(f"{base}/{path}", headers={
        "Authorization": f"Bearer {token()}", "User-Agent": UA, **cf_headers()})
    try:
        body = urllib.request.urlopen(req, timeout=40).read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "ignore")
    except Exception as e:
        return {"_error": f"{type(e).__name__}: {e}", "_endpoint": path}
    try:
        return json.loads(body)
    except Exception:
        return {"_error": True, "_endpoint": path, "_raw": body[:200]}

def gql(query):
    req = urllib.request.Request(GQL, data=json.dumps({"query": query}).encode(),
        headers={"User-Agent": UA, "Content-Type": "application/json", **cf_headers()})
    return json.loads(urllib.request.urlopen(req, timeout=40).read().decode("utf-8", "ignore"))

def fetch(url):
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": UA, **cf_headers()}),
        timeout=40).read().decode("utf-8", "ignore")

def q(s):  # url-encode a path segment
    return urllib.parse.quote(str(s), safe="")

# ---- product helpers ------------------------------------------------------
def ca(p, code):
    for a in p.get("custom_attributes") or []:
        if a.get("attribute_code") == code:
            return a.get("value")
    return None

def salable_qty_attr(p):
    return (p.get("extension_attributes", {}) or {}).get("salable_qty") or 0

def load_raw():
    f = HERE / "bb-raw.jsonl"
    if not f.exists():
        sys.exit("no bb-raw.jsonl — run:  BB_TOKEN='…' python3 bellabike.py raw")
    rows = [json.loads(l) for l in open(f, encoding="utf-8") if l.strip()]
    meta = next((r for r in rows if "_meta" in r), {})
    prods = [r for r in rows if "_meta" not in r]
    return prods, meta.get("attribute_options", {})

def index(prods):
    by_sku = {p.get("sku"): p for p in prods}
    parent_of = {}
    for p in prods:
        if p.get("type_id") == "configurable":
            for cid in (p.get("extension_attributes", {}) or {}).get("configurable_product_links", []) or []:
                parent_of[str(cid)] = p
    return by_sku, parent_of

def dec(opts, code, v):
    if v in (None, ""): return None
    return opts.get(code, {}).get(str(v), v)

# ---- MSI salability (the resolved truth) ----------------------------------
def is_salable(sku, stock=WEBSITE_STOCK):
    r = rest(f"inventory/is-product-salable/{q(sku)}/{stock}")
    return r if isinstance(r, bool) else None

def salable_qty(sku, stock=WEBSITE_STOCK):
    r = rest(f"inventory/get-product-salable-quantity/{q(sku)}/{stock}")
    if isinstance(r, (int, float)): return r
    if isinstance(r, str):
        try: return float(r)
        except Exception: return None
    return None  # dict => not stockable / error

def in_catalog(sku):
    return gql('{products(filter:{sku:{eq:"%s"}}){total_count}}' % sku
               ).get("data", {}).get("products", {}).get("total_count", 0) > 0

# ===========================================================================
# DISCOVERY (token)
# ===========================================================================
def incat(cats):
    return ("searchCriteria[filter_groups][0][filters][0][field]=category_id"
            f"&searchCriteria[filter_groups][0][filters][0][value]={cats}"
            "&searchCriteria[filter_groups][0][filters][0][condition_type]=in")

def cmd_counts():
    print("all in eBike cats:", json.dumps(rest(f"products?{incat(CATSET)}&searchCriteria[pageSize]=1&fields=total_count")))
    vis = ("&searchCriteria[filter_groups][1][filters][0][field]=visibility"
           "&searchCriteria[filter_groups][1][filters][0][value]=2,3,4"
           "&searchCriteria[filter_groups][1][filters][0][condition_type]=in")
    print("visible listings:", json.dumps(rest(f"products?{incat(CATSET)}{vis}&searchCriteria[pageSize]=1&fields=total_count")))

def cmd_tree():
    print(json.dumps(rest("categories?rootCategoryId=50&fields=id,name,is_active,children_data[id,name,is_active]"), indent=2))

def build_opts():
    print("  building spec dictionaries…", file=sys.stderr)
    out = {}
    for code in SPEC_CODES:
        o = rest(f"products/attributes/{code}/options")
        m = {}
        if isinstance(o, list):
            for it in o:
                if it.get("value") not in (None, ""):
                    m[str(it["value"])] = it.get("label")
        out[code] = m
    return out

def cmd_raw(argv):
    size = int(argv[0]) if argv else 100
    out = HERE / "bb-raw.jsonl"
    opts = build_opts()
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"_meta": {"fetched_at": datetime.datetime.utcnow().isoformat()+"Z",
            "source": "bellabike.ro /products cat 50,721,722,723,725,751 — all visibilities",
            "note": "line1 = meta+attribute_options; rest = full product objects"},
            "attribute_options": opts}) + "\n")
        page, got, total = 1, 0, 0
        while True:
            resp = rest(f"products?{incat(CATSET)}&searchCriteria[pageSize]={size}&searchCriteria[currentPage]={page}")
            if isinstance(resp, dict) and resp.get("_error"):
                sys.exit(f"ERROR page {page}: {resp}")
            items = resp.get("items") or []
            if not items: break
            total = resp.get("total_count", 0)
            for it in items: fh.write(json.dumps(it, ensure_ascii=False) + "\n")
            got += len(items); print(f"    page {page}: +{len(items)} ({got}/{total})", file=sys.stderr)
            if page * size >= total: break
            page += 1
    print(f"  wrote {out}: 1 meta line + {got} product lines", file=sys.stderr)

# ===========================================================================
# OFFLINE census (no token)
# ===========================================================================
def cmd_census():
    prods, opts = load_raw()
    def tally(items, keyf):
        c = {}
        for it in items: c[str(keyf(it))] = c.get(str(keyf(it)), 0) + 1
        return dict(sorted(c.items(), key=lambda kv: -kv[1]))
    out = {
        "total": len(prods),
        "old_prefixed": sum(1 for p in prods if str(p.get("sku") or "").startswith("OLD")),
        "price_zero": sum(1 for p in prods if (float(p.get("price") or 0) == 0)),
        "by_type": tally(prods, lambda p: p.get("type_id")),
        "by_visibility": tally(prods, lambda p: p.get("visibility")),
        "by_status": tally(prods, lambda p: p.get("status")),
        "by_disponibilitate": tally(prods, lambda p: dec(opts, "disponibilitate_stocuri", ca(p, "disponibilitate_stocuri")) or "(blank)"),
    }
    (HERE / "bb-census.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(json.dumps(out, indent=2, ensure_ascii=False))

# ===========================================================================
# STOREFRONT cross-check (no token)
# ===========================================================================
def effective_price(p):
    price = float(p.get("price") or 0)
    sp = ca(p, "special_price")
    if sp:
        spv = float(sp)
        def pdt(d):
            try: return datetime.datetime.strptime((d or "")[:19], "%Y-%m-%d %H:%M:%S")
            except Exception: return None
        f, t = pdt(ca(p, "special_from_date")), pdt(ca(p, "special_to_date"))
        now = datetime.datetime.now()
        if 0 < spv < price and (f is None or f <= now) and (t is None or t >= now):
            return spv
    return price

_vcache = {}
def parent_variants(psku):
    if psku in _vcache: return _vcache[psku]
    qr = ('{products(filter:{sku:{eq:"%s"}}){items{... on ConfigurableProduct{variants{product{'
          'sku stock_status price_range{minimum_price{final_price{value}}}}}}}}}' % psku)
    out = {}
    try:
        for it in gql(qr).get("data", {}).get("products", {}).get("items", []):
            for v in it.get("variants") or []:
                pr = v.get("product", {})
                out[pr.get("sku")] = {
                    "final": pr.get("price_range", {}).get("minimum_price", {}).get("final_price", {}).get("value"),
                    "stock_status": pr.get("stock_status")}
    except Exception as e:
        out = {"_error": str(e)}
    _vcache[psku] = out
    return out

def jsonld(h):
    for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', h, re.S):
        try: d = json.loads(m.group(1))
        except Exception: continue
        if isinstance(d, dict) and d.get("@type") in ("Product", "ProductGroup"): return d
    return None

def cmd_check(argv):
    n = int(argv[0]) if argv else 12
    mode = argv[1] if len(argv) > 1 else "mix"
    prods, opts = load_raw()
    by_sku, parent_of = index(prods)
    en = lambda p: p.get("status") == 1
    simples = [p for p in prods if p.get("type_id") == "simple" and p.get("price")
               and str(p.get("id")) not in parent_of and p.get("visibility") == 4 and en(p)]
    children = [p for p in prods if str(p.get("id")) in parent_of and p.get("price") and en(p)]
    pool = {"simples": simples, "children": children, "mix": simples + children}[mode]
    random.shuffle(pool); sample = pool[:n]
    npass = {"price": 0}
    print(f"\n== E2E spot-check: {len(sample)} {mode} (dump vs live storefront) ==\n")
    print(f"{'SKU':<16}{'kind':<10}{'PRICE':<26}{'storefront stock'}")
    for p in sample:
        sku, eff = p.get("sku"), effective_price(p)
        pv = "ERROR"
        if str(p.get("id")) in parent_of:
            par = parent_of[str(p.get("id"))]
            info = parent_variants(par.get("sku")).get(sku)
            sfp = info.get("final") if info else None
            stk = info.get("stock_status") if info else "absent(OOS/hidden)"
            pv = "no-gql" if sfp is None else ("PASS" if abs(float(sfp)-eff) < 1 else f"DIFF {eff}/{sfp}")
            print(f"{sku:<16}{'child':<10}{pv:<26}{stk}")
        else:
            try:
                h = fetch("https://bellabike.ro/" + (ca(p, "url_key") or ""))
                ld = jsonld(h) or {}; off = ld.get("offers") or {}
                if isinstance(off, list): off = off[0] if off else {}
                sfp = off.get("price"); avail = (off.get("availability") or "").split("/")[-1]
                pv = "no-price" if sfp in (None, "") else ("PASS" if abs(float(sfp)-eff) < 1 else f"DIFF {eff}/{sfp}")
                print(f"{sku:<16}{'simple':<10}{pv:<26}{avail}")
            except Exception as e:
                print(f"{sku:<16}{'simple':<10}ERROR {e}")
            time.sleep(0.3)
        if pv == "PASS": npass["price"] += 1
    print(f"\nPASS price={npass['price']}/{len(sample)}")

def unique_parents_of_fps():
    prods, _ = load_raw()
    by_sku, parent_of = index(prods)
    mm = json.loads((HERE / "bb-mismatch.json").read_text()) if (HERE/"bb-mismatch.json").exists() else None
    if not mm:
        sys.exit("no bb-mismatch.json — run:  python3 bellabike.py mismatch")
    fps = [r["sku"] for r in mm["false_positives"]]
    seen, parents = set(), []
    for sku in fps:
        par = parent_of.get(str((by_sku.get(sku) or {}).get("id")))
        if par and par.get("sku") not in seen:
            seen.add(par.get("sku")); parents.append(par)
    return fps, parents

def cmd_mismatch():
    prods, _ = load_raw()
    by_sku, parent_of = index(prods)
    en = lambda p: p.get("status") == 1
    simples = [p for p in prods if p.get("type_id") == "simple" and p.get("price")
               and str(p.get("id")) not in parent_of and p.get("visibility") == 4 and en(p)]
    children = [p for p in prods if str(p.get("id")) in parent_of and p.get("price") and en(p)]
    print(f"buyable: {len(simples)} simples + {len(children)} children", file=sys.stderr)
    parents = {}
    for c in children:
        parents.setdefault(parent_of[str(c.get("id"))].get("sku"), set()).add(c.get("sku"))
    sf = {}
    print(f"sweeping {len(parents)} parents via GraphQL…", file=sys.stderr)
    for i, (psku, kids) in enumerate(parents.items(), 1):
        present = {k: v["stock_status"] for k, v in parent_variants(psku).items() if isinstance(v, dict) and "stock_status" in v}
        for k in kids: sf[k] = present.get(k, "OUT_OF_STOCK")
        if i % 50 == 0: print(f"  {i}/{len(parents)}", file=sys.stderr)
        time.sleep(0.2)
    fp, fn = [], []
    for c in children:
        ours = salable_qty_attr(c) > 0; sfin = sf.get(c.get("sku")) == "IN_STOCK"
        if ours and not sfin: fp.append({"sku": c.get("sku"), "salable": salable_qty_attr(c), "name": c.get("name")})
        elif sfin and not ours: fn.append({"sku": c.get("sku"), "salable": salable_qty_attr(c), "name": c.get("name")})
    total = len(simples) + len(children)
    out = {"comparable": total, "false_positives": fp, "false_negatives": fn}
    (HERE / "bb-mismatch.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(f"\nFALSE-POSITIVES: {len(fp)} ({100*len(fp)/total:.2f}%)   FALSE-NEGATIVES: {len(fn)}")
    print("(these are catalog-VISIBILITY artifacts, not stock — see `confirm`)\nwrote bb-mismatch.json")

def cmd_confirm():
    fps, parents = unique_parents_of_fps()
    prods, _ = load_raw()
    has_tok = bool(os.environ.get("BB_TOKEN"))
    print(f"Confirming {len(fps)} flagged SKUs under {len(parents)} parents"
          + ("  (DB side ON)" if has_tok else "  (storefront only — set BB_TOKEN for DB side)") + "\n")
    absent = sal_false = 0
    def mq(name):
        n = re.sub(r"^Bicicleta\s+(Electrica|FS Electrica|Electrica Full Suspension)?\s*", "", name or "", flags=re.I)
        n = re.sub(r"\b(Full Suspension|Hardtail|Trekking|Oras|Cross|MTB|Urban|Gravel|Road)\b", " ", n, flags=re.I)
        return re.sub(r"\s+", " ", n).strip()
    for par in parents:
        psku, pname, purl = par.get("sku"), par.get("name"), ca(par, "url_key")
        cat = in_catalog(psku)
        if not cat: absent += 1
        line = f"### {pname}\n  parent {psku} | catalog: {'PRESENT ✗' if cat else 'ABSENT ✓'}"
        if has_tok:
            s = is_salable(psku)
            if s is False: sal_false += 1
            line += f" | is-salable/2: {s} {'✓' if s is False else '✗'}"
        print(line)
        print(f"  orphan listing : https://bellabike.ro/{purl}")
        print(f"  site search    : https://bellabike.ro/catalogsearch/result/?q={urllib.parse.quote(mq(pname))}")
        try:
            sr = gql('{products(search:%s,pageSize:6){items{sku name url_key stock_status}}}' % json.dumps(mq(pname)))
            for it in [x for x in (sr.get("data",{}).get("products",{}).get("items",[]) or [])
                       if x.get("sku") != psku and (x.get("name") or "").lower().startswith("bicicleta")][:2]:
                print(f"  live replacement: {it['stock_status']:<9} https://bellabike.ro/{it.get('url_key')}  ({(it.get('name') or '')[:46]})")
        except Exception: pass
        print(); time.sleep(0.25)
    print("=" * 64)
    print(f"STOREFRONT: {absent}/{len(parents)} parents ABSENT from catalog  ({'PASS' if absent==len(parents) else 'CHECK'})")
    if has_tok:
        print(f"DB GATE   : {sal_false}/{len(parents)} parents is-salable/2 == false  ({'PASS' if sal_false==len(parents) else 'CHECK'})")
        for c in ["OLD454124", "OLD290592"]:
            print(f"  control {c}: catalog={'PRESENT' if in_catalog(c) else 'ABSENT'}  is-salable/2={is_salable(c)}")

# ===========================================================================
# MSI / stock truth (token)
# ===========================================================================
def cmd_gate(argv):
    full = "--full" in argv
    prods, _ = load_raw()
    by_sku, parent_of = index(prods)
    parents = [p for p in prods if p.get("type_id") == "configurable" and p.get("status") == 1]
    simples = [p for p in prods if p.get("type_id") == "simple" and p.get("price")
               and str(p.get("id")) not in parent_of and p.get("visibility") == 4 and p.get("status") == 1]
    print(f"gate: {len(parents)} configurable parents + {len(simples)} standalone simples "
          f"(membership via is-product-salable/{WEBSITE_STOCK})…", file=sys.stderr)
    buyable_parents, excluded_parents = [], []
    for i, p in enumerate(parents, 1):
        ok = is_salable(p.get("sku")) is True
        (buyable_parents if ok else excluded_parents).append(p.get("sku"))
        if i % 100 == 0: print(f"  {i}/{len(parents)} parents", file=sys.stderr)
        time.sleep(0.1)
    buyable_simples = [s.get("sku") for s in simples if is_salable(s.get("sku")) is True]
    # cross-check: every parent of the 23 flagged SKUs must be EXCLUDED
    flagged_parents = set()
    if (HERE / "bb-mismatch.json").exists():
        for sku in [r["sku"] for r in json.loads((HERE/"bb-mismatch.json").read_text())["false_positives"]]:
            par = parent_of.get(str((by_sku.get(sku) or {}).get("id")))
            if par: flagged_parents.add(par.get("sku"))
    leaked = [p for p in flagged_parents if p in buyable_parents]
    out = {"buyable_parents": buyable_parents, "excluded_parents": excluded_parents,
           "buyable_simples": buyable_simples, "flagged_parents_excluded": sorted(flagged_parents - set(leaked)),
           "flagged_parents_LEAKED": leaked}
    buyable_children = None
    if full:
        print("  --full: checking each child of buyable parents…", file=sys.stderr)
        buyable_children = []
        for i, psku in enumerate(buyable_parents, 1):
            par = by_sku.get(psku)
            for cid in (par.get("extension_attributes", {}) or {}).get("configurable_product_links", []) or []:
                child = next((x for x in prods if str(x.get("id")) == str(cid)), None)
                if child and is_salable(child.get("sku")) is True:
                    buyable_children.append(child.get("sku"))
            if i % 50 == 0: print(f"  {i}/{len(buyable_parents)} parents' children", file=sys.stderr)
            time.sleep(0.05)
        out["buyable_children"] = buyable_children
    (HERE / "bb-buyable.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(f"\nbuyable parents : {len(buyable_parents)} / {len(parents)}")
    print(f"buyable simples : {len(buyable_simples)} / {len(simples)}")
    if buyable_children is not None:
        print(f"buyable child SKUs (net online catalog): {len(buyable_children)} + {len(buyable_simples)} simples"
              f" = {len(buyable_children)+len(buyable_simples)}")
    print(f"flagged-parent leak check: {len(leaked)} leaked  "
          f"({'PASS — all 0.6% excluded' if not leaked else 'FAIL: '+str(leaked)})")
    print("wrote bb-buyable.json")

def _per_stock(sku, stocks):
    for sid in stocks:
        print(f"    stock_id={sid}  salable_qty={salable_qty(sku, sid)}  is_salable={is_salable(sku, sid)}")

def cmd_salable(argv):
    if not argv: sys.exit("usage: salable SKU [SKU...]")
    stocks = [str(s.get("stock_id")) for s in (rest("inventory/stocks?searchCriteria[pageSize]=50").get("items") or [])]
    for sku in argv:
        print(f"== {sku} =="); _per_stock(sku, stocks)

def cmd_sources(argv):
    if not argv: sys.exit("usage: sources SKU [SKU...]")
    st = rest("inventory/stocks?searchCriteria[pageSize]=50")
    print("== stocks (each = one sales channel) ==")
    for s in st.get("items") or []:
        ch = ", ".join(f"{c.get('type')}:{c.get('code')}" for c in (s.get("extension_attributes",{}) or {}).get("sales_channels") or [])
        print(f"  stock_id={s.get('stock_id')}  name={s.get('name')}  channels=[{ch}]")
    print("== sources ==")
    for s in rest("inventory/sources?searchCriteria[pageSize]=50").get("items") or []:
        print(f"  {s.get('source_code')}  enabled={s.get('enabled')}  name={s.get('name')}")
    stocks = [str(s.get("stock_id")) for s in (st.get("items") or [])]
    for sku in argv:
        print(f"\n== {sku} ==")
        si = rest(f"inventory/source-items?searchCriteria[filter_groups][0][filters][0][field]=sku"
                  f"&searchCriteria[filter_groups][0][filters][0][value]={q(sku)}"
                  f"&searchCriteria[filter_groups][0][filters][0][condition_type]=eq&searchCriteria[pageSize]=50")
        print("  -- per-source physical qty --")
        items = si.get("items") if isinstance(si, dict) else None
        if not items: print("    (no source-items)")
        else:
            for it in items: print(f"    source={it.get('source_code')}  qty={it.get('quantity')}  status={it.get('status')}")
        print("  -- per-stock salable (what each channel can sell) --"); _per_stock(sku, stocks)

def cmd_scope(argv):
    if not argv: sys.exit("usage: scope SKU [SKU...]   (env SV=storeViewCode, default 'default')")
    sv = os.environ.get("SV", "default")
    sbase = REST.replace("/V1", f"/{sv}/V1")
    def vs(p): return f"{p.get('visibility')}/{p.get('status')}" if isinstance(p, dict) and p.get("visibility") else "(err)"
    print(f"== visibility/status — admin vs store-view '{sv}'  (vis 1=NotVisIndiv,4=Both) ==")
    print(f"  {'SKU':<24}{'admin':<14}{'store':<14}verdict")
    for sku in argv:
        a = vs(rest(f"products/{q(sku)}")); s = vs(rest(f"products/{q(sku)}", base=sbase))
        v = "HIDDEN@store" if s.startswith("1/") else "visible"
        print(f"  {sku:<24}{a:<14}{s:<14}{v}")

def cmd_avail(argv):
    if not argv: sys.exit("usage: avail SKU")
    s = argv[0]; p = rest(f"products/{q(s)}")
    print(json.dumps({"sku": p.get("sku"), "name": p.get("name"), "price": p.get("price"),
        "status": p.get("status"), "type_id": p.get("type_id"),
        "salable_qty_attr": salable_qty_attr(p),
        "is_salable_website": is_salable(s), "salable_qty_website": salable_qty(s),
        "disponibilitate_stocuri": ca(p, "disponibilitate_stocuri")}, indent=2, ensure_ascii=False))

# ===========================================================================
# MEMBERSHIP via SITEMAP (no token, lightest) — "is this in the browsable catalog?"
# ===========================================================================
def cmd_sitemap():
    """Fetch the public sitemap (the browsable catalog) and mark which dump
    parents/simples are IN catalog. The light, no-token membership signal."""
    idx = fetch("https://bellabike.ro/sitemap.xml")
    subs = re.findall(r'<loc>\s*([^<]+?sitemap[^<]+?)\s*</loc>', idx) or ["https://bellabike.ro/sitemap.xml"]
    keys = set()
    for su in subs:
        try: body = fetch(su.strip())
        except Exception as e: print(f"  {su}: {e}", file=sys.stderr); continue
        for loc in re.findall(r'<loc>\s*([^<]+?)\s*</loc>', body):
            keys.add(loc.rstrip("/").split("/")[-1].lower())
        time.sleep(0.2)
    print(f"sitemap: {len(subs)} sub-sitemaps, {len(keys)} URL slugs", file=sys.stderr)
    prods, _ = load_raw(); by_sku, parent_of = index(prods)
    parents = [p for p in prods if p.get("type_id") == "configurable" and p.get("status") == 1]
    simples = [p for p in prods if p.get("type_id") == "simple" and p.get("price")
               and str(p.get("id")) not in parent_of and p.get("visibility") == 4 and p.get("status") == 1]
    in_cat, not_cat = [], []
    for p in parents + simples:
        uk = (ca(p, "url_key") or "").rstrip("/").split("/")[-1].lower()
        (in_cat if uk and uk in keys else not_cat).append(p.get("sku"))
    out = {"sub_sitemaps": subs, "slug_count": len(keys), "in_catalog": in_cat, "not_in_catalog": not_cat}
    (HERE / "bb-sitemap.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(f"of {len(parents)+len(simples)} parents+simples: IN catalog={len(in_cat)}  NOT={len(not_cat)}")
    if (HERE / "bb-verify.json").exists():
        v = json.loads((HERE / "bb-verify.json").read_text())
        gql_present = v["present_salable"] + v["present_NOTsalable_listedOOS"]
        print(f"cross-check: sitemap says {len(in_cat)} in-catalog vs GraphQL verify {gql_present} present "
              f"({'MATCH' if abs(len(in_cat)-gql_present) <= 3 else 'DIFF — inspect'})")
    print("wrote bb-sitemap.json")

# ===========================================================================
# FULL CROSS-CHECK — DB gate vs live storefront over the WHOLE population
# ===========================================================================
def cmd_verify():
    """For EVERY configurable parent + standalone simple: DB is-product-salable/2
    vs storefront catalog presence (+stock_status). Proves the gate 1:1, or
    surfaces every exception. Run a fresh `raw` first."""
    from collections import Counter
    prods, _ = load_raw()
    by_sku, parent_of = index(prods)
    parents = [p for p in prods if p.get("type_id") == "configurable" and p.get("status") == 1]
    simples = [p for p in prods if p.get("type_id") == "simple" and p.get("price")
               and str(p.get("id")) not in parent_of and p.get("visibility") == 4 and p.get("status") == 1]
    targets = [(p.get("sku"), "parent") for p in parents] + [(p.get("sku"), "simple") for p in simples]
    skus = [s for s, _ in targets]
    # storefront presence + stock_status, batched (absent skus simply don't return)
    present = {}
    B = 80
    print(f"verify: {len(parents)} parents + {len(simples)} simples; GraphQL presence (batched)…", file=sys.stderr)
    for i in range(0, len(skus), B):
        batch = skus[i:i+B]
        inlist = ",".join(json.dumps(s) for s in batch)
        try:
            for it in gql('{products(filter:{sku:{in:[%s]}},pageSize:%d){items{sku stock_status}}}' % (inlist, B)
                          ).get("data", {}).get("products", {}).get("items", []):
                present[it.get("sku")] = it.get("stock_status")
        except Exception as e:
            print(f"  gql batch err: {e}", file=sys.stderr)
        print(f"  graphql {min(i+B, len(skus))}/{len(skus)}", file=sys.stderr); time.sleep(0.2)
    # DB gate, per sku (token)
    print(f"  is-product-salable/2 for {len(skus)} skus…", file=sys.stderr)
    sal = {}
    for i, s in enumerate(skus, 1):
        sal[s] = is_salable(s)
        if i % 100 == 0: print(f"  is-salable {i}/{len(skus)}", file=sys.stderr)
        time.sleep(0.05)
    # confusion matrix on (in_catalog ?, is-salable/2 ?)
    mat = Counter(); diff = []
    for s, kind in targets:
        inc = s in present; ok = sal.get(s) is True
        mat[(inc, ok)] += 1
        if inc != ok:
            diff.append({"sku": s, "kind": kind, "in_catalog": inc,
                         "stock_status": present.get(s), "is_salable_2": sal.get(s)})
    tot = len(targets); agree = mat[(True, True)] + mat[(False, False)]
    out = {"total": tot, "agreement_pct": round(100*agree/tot, 3),
           "present_salable": mat[(True, True)], "absent_notsalable": mat[(False, False)],
           "present_NOTsalable_listedOOS": mat[(True, False)], "absent_salable_INVESTIGATE": mat[(False, True)],
           "disagreements": diff}
    (HERE / "bb-verify.json").write_text(json.dumps(out, indent=2, ensure_ascii=False))
    print(f"\n== verify: DB is-product-salable/2  vs  storefront catalog ({tot} parents+simples) ==")
    print(f"  present + salable      : {mat[(True, True)]}")
    print(f"  absent  + not-salable  : {mat[(False, False)]}   (hidden — correctly excluded)")
    print(f"  present + NOT salable  : {mat[(True, False)]}   (listed-but-OOS — membership yes, stock no)")
    print(f"  absent  + salable      : {mat[(False, True)]}   (expect ~0)")
    print(f"  AGREEMENT (is-salable ⟺ in-catalog): {agree}/{tot} = {100*agree/tot:.3f}%\n")
    if mat[(True, False)] == 0 and mat[(False, True)] == 0:
        print("  ✅ is-product-salable/2 == storefront catalog membership, 100%. DB-only gate proven over the whole catalog.")
    else:
        if mat[(True, False)]:
            ex = [d["sku"] for d in diff if d["in_catalog"]][:6]
            print(f"  ⚠️ {mat[(True, False)]} LISTED-but-OOS parents → for these, membership = catalog presence and")
            print(f"     is-salable/2 is the in_stock FLAG (sync as in_stock=false), not a membership drop.  e.g. {ex}")
        if mat[(False, True)]:
            ex = [d["sku"] for d in diff if not d["in_catalog"]][:6]
            print(f"  ⚠️ {mat[(False, True)]} salable-but-ABSENT (investigate): {ex}")
    print("wrote bb-verify.json")

# ===========================================================================
# ORCHESTRATOR
# ===========================================================================
def cmd_validate():
    print("### 1) census (offline)\n"); cmd_census()
    print("\n### 2) gate — RESOLVED buyable membership (token)\n"); cmd_gate([])
    print("\n### 3) confirm — 0.6% two-sided proof (token)\n"); cmd_confirm()
    print("\n### 4) check — storefront price spot-check (8)\n"); cmd_check(["8", "mix"])
    print("\n=== validate done ===")

# ===========================================================================
# AUDIT a sync run (our Supabase DB vs BellaBike storefront)
# ===========================================================================
def cmd_audit(argv):
    """Reconcile a bike-sync run. Prints the Supabase SQL to inspect the run +
    what we wrote, then runs `verify` (Magento is-product-salable/2 vs storefront
    GraphQL membership) as the storefront cross-check. Needs BB_TOKEN + a fresh
    `raw` dump for the verify pass."""
    if not argv:
        sys.exit("usage: audit <run_id>   (BB_TOKEN needed for the verify pass)")
    run_id = argv[0]
    print(f"== audit sync run {run_id} ==\n")
    print("1) Inspect the run in Supabase (psql / SQL editor):")
    print(f"   select * from sync_run_summary where id = '{run_id}';")
    print( "   select branch, kind, category_id, status, attempts, n_fetched,")
    print( "          n_upserted, n_models_upserted, n_failed, error")
    print(f"     from sync_units where run_id = '{run_id}' order by branch, created_at;")
    print( "   select count(*) as offers,")
    print( "          count(*) filter (where in_stock)  as in_stock,")
    print( "          count(*) filter (where in_catalog) as in_catalog,")
    print( "          count(*) filter (where active)     as active")
    print( "     from bikes where source = 'bellabike';")
    print( "   select count(*) as models,")
    print( "          count(*) filter (where in_catalog) as in_catalog")
    print( "     from bike_models")
    print( "     where dealer_id = '099380e6-5991-4acc-b737-9815365bf9d1';\n")
    print("2) Storefront reconcile — Magento is-product-salable/2 vs storefront")
    print("   GraphQL catalog membership over the whole catalog:\n")
    cmd_verify()

# ===========================================================================
USAGE = """bellabike.py — the ONE BellaBike read-only tool.  export BB_TOKEN='…' for token cmds.

  discovery (token):   counts | tree | raw [pageSize]
  offline (no token):  census
  storefront (no tok):  check [N] [simples|children|mix] | mismatch | confirm
  MSI/stock (token):   gate [--full] | salable SKU… | sources SKU… | scope SKU… | avail SKU
  full cross-check:    verify   (DB gate vs storefront over WHOLE catalog — needs token)
  sync audit (token):  audit <run_id>   (Supabase run SQL + storefront verify)
  orchestrator (token): validate

Resolved model: online salability = is-product-salable/{sku}/2 (website stock),
applied at the PARENT for configurables (catalog membership) and per CHILD for size.
`gate` applies it; `confirm` proves the 0.6% (hidden OLD… listings) are excluded."""
def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    a = sys.argv[2:]
    table = {
        "counts": cmd_counts, "tree": cmd_tree, "raw": lambda: cmd_raw(a),
        "census": cmd_census, "check": lambda: cmd_check(a), "mismatch": cmd_mismatch,
        "confirm": cmd_confirm, "gate": lambda: cmd_gate(a), "salable": lambda: cmd_salable(a),
        "sources": lambda: cmd_sources(a), "scope": lambda: cmd_scope(a),
        "avail": lambda: cmd_avail(a), "sitemap": cmd_sitemap,
        "verify": cmd_verify, "validate": cmd_validate,
        "audit": lambda: cmd_audit(a),
    }
    if cmd in ("help", "-h", "--help") or cmd not in table:
        print(USAGE); sys.exit(0 if cmd.startswith(("h","-")) else 2)
    table[cmd]()

if __name__ == "__main__":
    main()
