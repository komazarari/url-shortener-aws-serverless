# QR codes — design proposal

Status: Phase 1 implemented, together with the switch to 10-hex-digit keys
that section 2 argues for. Phase 2 not started.

The shortener exists so that a long share URL fits in a small QR code. Right
now the admin page hands back a short link and stops there, which leaves the
actual goal — a printable sticker — outside the tool. This adds it.

---

## 1. Scope

**Phase 1.** A "Show QR" button on the admin page: for the link you just
created, and for any key you look up. Renders SVG, downloads SVG or PNG.
**No API change, no IAM change, no CloudFront change.**

**Phase 2.** A list of every registered link, each row with its own QR button.
Needs a new `GET /api/links`. Sketched in section 7, deliberately not decided
here — the ordering problem in 7.2 deserves its own round.

**Not in scope:** editing, deleting, custom aliases, logo-in-the-middle QR,
batch sticker sheets. Deleting in particular stays out: the API has no
`s3:DeleteObject` and a `301` already handed out cannot be recalled
(design.md 8.2).

---

## 2. Read this before printing anything

The motivating use case — turning a Google Docs or Evernote **share URL** into
a sticker — collides with design.md 3.2, which ends with "**Do not shorten URLs
that are themselves secrets.**" A share URL *is* a secret: possession of it is
the authorization. Shortening one replaces its ~120 bits of unguessable path
with a short key reachable by anyone at `https://<domain>/<key>` with no
authentication.

When this was written, that key was **8 hex digits of CRC32, 32 bits**. It is
now **10 hex digits of truncated SHA-256, 40 bits** (design.md 3.4, 3.5); keys
minted before the switch keep their 8 digits. What each costs:

| | Original share URL | 8-digit CRC32 (legacy) | 10-digit SHA-256 (current) |
| --- | --- | --- | --- |
| Guessing space | ~2^120 | 2^32 | **2^40** |
| Cost of a full sweep | impossible | ~4.3 B `GET`s — weeks, **billed to you** | ~1.1 T `GET`s |
| Confirming a URL you already suspect | not possible | CRC32 it and fetch | hash it and fetch |
| Physical exposure | none | **anyone who can see the sticker** | **anyone who can see the sticker** |

None of this is an argument against the feature. It is an argument for
deciding, per link, whether the target is a capability or just a long URL. Two
levers, in order of cheapness:

**Longer keys cost almost nothing in QR size.** This is the surprise in the
measurements below: on every domain measured, 8, 10 and 12 hex digits produce
*the same* code. That is why the default went to 10 digits for everyone rather
than an opt-in `key_length`: the extra keyspace is free, and a per-link width
would need the length recorded somewhere the key alone cannot carry
(design.md 9). Ten rather than twelve keeps the key comfortable to read aloud
or type, and 2^40 is already past what a sweep billed to the owner can reach.
Confirming a *suspected* URL is still just a hash and a `GET` — no key width
fixes that.

**The sticker is the weakest link regardless.** A QR on a laptop lid is
readable across a room and photographs well. For anything genuinely
confidential, the answer is not a shorter key or a longer one; it is not
putting it on a sticker.

---

## 3. How small does it actually get

Measured with `qrcode-generator` 2.0.4, byte mode, module counts including no
quiet zone. Version numbers omitted; what matters is the module count, because
that is what sets how fine the print has to be.

| Domain | Key | URL chars | EC=L | EC=M | EC=Q |
| --- | --- | --- | --- | --- | --- |
| `ex.am` | 8 hex | 22 | **25** | **25** | 29 |
| `ex.am` | 10 hex | 24 | **25** | **25** | 29 |
| `ex.am` | 12 hex | 26 | **25** | **25** | 29 |
| `ex.am` | 16 hex | 30 | **25** | 29 | 29 |
| `ab.example` | 8 hex | 27 | **25** | 29 | 29 |
| `ab.example` | 10 hex | 29 | **25** | 29 | 29 |
| `ab.example` | 12 hex | 31 | **25** | 29 | 29 |
| `short.example.com` | 8 hex | 34 | 29 | 29 | 33 |
| `short.example.com` | 10 hex | 36 | 29 | 29 | 33 |
| `short.example.com` | 12 hex | 38 | 29 | 29 | 33 |
| `short.example.com` | 16 hex | 42 | 29 | 29 | 33 |
| `go.link.example.com` | 8 hex | 36 | 29 | 29 | 33 |
| `go.link.example.com` | 10 hex | 38 | 29 | 29 | 33 |

Three readings:

**The domain dominates.** Four characters of domain cost as much as four
characters of key. Going from `short.example.com` to `ex.am` is worth a whole
version; going from an 8-hex key to a 10- or 12-hex one is usually worth
nothing. If
QR size is the point of the project, the domain is the lever.

**Error correction is the other lever.** `EC=L` recovers ~7 % damage, `M` ~15 %.
A clean laser-printed sticker on a flat surface has no damage to recover from —
`L` is the right default *for this use*, and it buys back a version on the
common case. `Q` and `H` exist for codes that get scuffed or have a logo
punched through the middle; neither applies here.

**Then convert to millimetres.** Module pitch, including the mandatory
4-module quiet zone:

| Code | +QZ | 15 mm | 20 mm | 25 mm | 30 mm | 40 mm |
| --- | --- | --- | --- | --- | --- | --- |
| 25×25 | 33 | 0.45 | 0.61 | 0.76 | 0.91 | 1.21 |
| 29×29 | 37 | 0.41 | 0.54 | 0.68 | 0.81 | 1.08 |
| 33×33 | 41 | 0.37 | 0.49 | 0.61 | 0.73 | 0.98 |

Phone cameras want roughly 0.4 mm per module or better at normal reading
distance, and cheap label printers blur below about 0.5 mm. So a **20 mm
sticker at 29×29 works, a 15 mm one is marginal**, and shaving the code to
25×25 is what makes 15 mm comfortable. That is the whole reason the two levers
above matter.

**The quiet zone is not decoration.** Four blank modules on every side, or
scanners fail. It must be baked into the exported file, because whoever crops
the image later will crop it away.

---

## 4. Generating it in the browser

Yes, entirely client-side. design.md 9 already anticipated this ("Generate
client-side; no server work") and nothing has changed to contradict it.

### 4.1 Library

| Option | Size (min / gzip) | SVG out | Alphanumeric mode | Note |
| --- | --- | --- | --- | --- |
| **`qrcode-generator` 2.0.4** | 57 KB raw / **12 KB** | yes | yes | MIT, Kazuhiko Arase, the de-facto reference implementation |
| `qrcode-svg` 1.1.0 | 19 KB / 6 KB | yes | no | wrapper over the same core, fewer knobs |
| `qr-creator` 1.0.0 | 12 KB / 5 KB | **no** — canvas only | no | smallest, wrong output format |
| Hand-rolled | ~250 lines | — | — | Reed–Solomon over GF(2^8), masking, format info. Correct is not the hard part; *staying* correct is |

**Choose `qrcode-generator`, vendored.** It is the only one on the list with
both SVG output and explicit mode selection, and the mode selector keeps the
uppercase-alias idea (appendix A) open without changing libraries later. Twelve
kilobytes over the wire on a page that already requires an OIDC round trip is
not a cost worth optimising.

Take `dist/qrcode.js`, **not** `qrcode_UTF8.js` — short URLs are ASCII by
construction, so the UTF-8 shim is dead weight.

Hand-rolling deserves one sentence of defence, because it fits the repo's
temperament: everything else here is code you can read end to end. The
counter-argument is that a QR encoder is the one component where a subtle bug
produces output that scans fine on your phone and fails on the customer's, and
there is no test you would actually run to catch it. Vendor it, pin it, note
the version.

### 4.2 Delivery

Serve it as a **separate object**, not inlined into `admin.html`:

```hcl
resource "aws_s3_object" "admin_qrcode_js" {
  bucket        = aws_s3_bucket.admin.id
  key           = "admin/qrcode.js"
  source        = "${path.module}/../web/vendor/qrcode.js"
  etag          = filemd5("${path.module}/../web/vendor/qrcode.js")
  content_type  = "text/javascript; charset=utf-8"
  cache_control = "max-age=60"
}
```

**The key `admin/qrcode.js` coexists with the key `admin`.** S3 has no
directories, so an object named `admin` and a prefix `admin/` are unrelated
strings; nothing collides. The existing `/admin*` behaviour routes it to the
same OAC origin, so the file is authenticated exactly like the page. **No new
CloudFront behaviour.**

Separate rather than inline for two reasons: `admin.html` stays readable as the
application, and a future `Content-Security-Policy` would not need
`'unsafe-inline'` to keep working. Set `content_type` correctly even though no
`nosniff` header is sent today.

Note that `/admin*` uses `Managed-CachingDisabled`, so the file is re-fetched on
every admin visit. `compress = true` is already set on that behaviour, so it is
12 KB each time. Acceptable; a dedicated cached behaviour for
`/admin/*.js` would be a real optimisation and a real complication, and 12 KB
does not justify it.

### 4.3 Rendering

Use the library for the encoding and build the SVG here, from
`getModuleCount()` and `isDark(r, c)`. About twenty lines, and it buys three
things that matter: an explicit quiet zone, an explicit white background rect,
and no `innerHTML` of a library-produced string.

```js
function qrSvg(text, ec = 'L', quiet = 4) {
  const qr = qrcode(0, ec);
  qr.addData(text, 'Byte');
  qr.make();
  const n = qr.getModuleCount();
  const size = n + quiet * 2;
  let d = '';
  for (let r = 0; r < n; r++)
    for (let c = 0; c < n; c++)
      if (qr.isDark(r, c)) d += `M${c + quiet},${r + quiet}h1v1h-1z`;
  return { size, modules: n, svg:
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" ` +
    `shape-rendering="crispEdges" width="100%" height="100%">` +
    `<rect width="${size}" height="${size}" fill="#fff"/>` +
    `<path d="${d}" fill="#000"/></svg>` };
}
```

**One module = one user unit**, so scaling is whatever the viewBox is rendered
at, and the SVG never carries a resolution.

**Black on white, always — never `currentColor`.** `admin.html` sets
`color-scheme: light dark` and paints everything in inherited colours. A QR
that inherits a dark theme is either invisible or, worse, inverted; most
scanners refuse inverted codes. The white `<rect>` matters for the same reason:
a transparent SVG dropped into a dark document stops scanning.

---

## 5. The modal

Native `<dialog>`. `showModal()` gives focus trapping, `Esc`, and the backdrop
for free, and adding a modal library to a page with no dependencies would be
absurd.

```
┌──────────────────────────────────────┐
│  ████ ▄▄ ████                        │
│  █  █ ██ █  █   https://…/1a2b3c4d5e │
│  ████ ▀▀ ████                        │
│   ▄▄▄▄▄▄▄▄▄▄                29 × 29  │
│  ████ ██ ████         ≈0.54 mm @20mm │
│                                      │
│  EC: (L) M  Q     [SVG] [PNG] [Copy] │
└──────────────────────────────────────┘
```

Showing the module count and the resulting pitch turns the guidance in section
3 into something you can act on while looking at the code, instead of a table
in a document nobody opens.

**SVG export** — `Blob` + `a[download]`, named `<key>.svg`. This is the format
for anything that will be printed.

**PNG export** — draw the modules straight onto a canvas with `fillRect`, at an
**integer pixel size per module**. Do not rasterise the SVG through an
`<img>`: it is slower, it introduces resampling blur at exactly the scale where
blur costs you scans, and it drags in the tainted-canvas rules for no reason.
An integer scale factor guarantees every module is the same number of pixels,
which is the single thing that keeps a small printed code crisp. Suggest a
fixed export around 1024 px (that is 27 px/module at 29×29) and let the label
software scale down.

**Copy** — `canvas.toBlob` into `ClipboardItem`. Image clipboard writes are
supported unevenly across browsers and require a secure context, so
feature-detect `window.ClipboardItem` and hide the button rather than failing
on click.

---

## 6. Phase 1 in full

The point of Phase 1 is that it touches nothing but the admin page.

| Change | File |
| --- | --- |
| Vendored encoder | `web/vendor/qrcode.js` (new) |
| "Show QR" next to Copy, modal, key lookup form | `web/admin.html` |
| One `aws_s3_object` | `terraform/admin_site.tf` |

Nothing else. No Lambda change, no IAM statement, no behaviour, no variable.

The key-lookup form uses `GET /api/links/{key}`, which already exists and is
already reachable through CloudFront. **Send `x-amz-content-sha256` on it too**
— the SHA-256 of the empty string,
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Whether OAC
handles a bodyless `GET` without it is **unverified**; sending the empty-body
hash unconditionally is one line and removes the question. If it turns out to
be unnecessary, deleting it later is free.

One failure mode is worth handling explicitly: the edge function returns **401
JSON** on an expired session (design.md 5.3), and the current page would render
that as a generic error. With a list view and repeated fetches this stops being
a curiosity — surface it as "session expired, reload" and reload.

---

## 7. Phase 2 sketch: the list

### 7.1 The endpoint

`GET /api/links` → `ListObjectsV2` + `HeadObject` per key.

**No Terraform change is needed.** `s3:ListBucket` is already granted on the
bucket, for the reason in design.md 4.4 — it was never about listing, but it
makes listing free.

The N+1 in design.md 9 is real but small: `HeadObject` is ~10–20 ms, so 500
links in a 16-way thread pool is well under a second, against a 10 s timeout
and 256 MB. It stops being fine somewhere in the low thousands, which is also
where the response payload starts to matter.

```jsonc
// 200
{
  "links": [ { "key": "...", "short_url": "...", "target_url": "...",
               "created_at": "...", "created_by": "..." } ],
  "truncated": false
}
```

`truncated` rather than a cursor — see below.

### 7.2 The ordering problem

**Keys are hashes, so `ListObjectsV2` order is meaningless.** It returns
lexicographic key order, and the keys are hash output. There is no "newest
first" available from S3 at all, and no cursor over the storage order can
produce one.

| Approach | Newest first | Cost | Verdict |
| --- | --- | --- | --- |
| Fetch everything, sort by `created-at` in the browser | yes | one full scan per load | **start here** |
| Page by `ContinuationToken` | **no** — pages are hash-ordered | cheap | fine for an "everything" dump, useless as the primary UI |
| Index object, updated on create | yes | O(1) reads | deferred, see below |

Take the first: scan, sort client-side, and set `truncated: true` if the scan
hits a cap (a few thousand). It is correct at the stated scale of design.md 1
and it adds no state to keep consistent.

**If the index becomes necessary, it must not live in the redirect bucket.**
Every object there is served by the S3 website endpoint under the public
default behaviour, so an `index.json` at the root would be a public dump of
every link and target — an accidental total inversion of "no listing
endpoint". It would have to go in the **admin** bucket, which then needs a
`s3:PutObject` grant for the API role on a bucket it currently cannot touch,
plus a rebuild path for when the index and the objects disagree. That is a
larger change than it first looks; hence deferred.

### 7.3 In the UI

Rows of short link, target, created at, `Copy`, `Show QR`. Sorted newest first.
An explicit refresh button rather than a poll: `/api/*` is `CachingDisabled`,
so every load is a full scan, and nothing here changes without the user
creating it.

---

## 8. What this adds to the threat model

design.md 8.1 now carries both consequences: a "printed QR sticker" row, and a
"key enumeration" row rewritten for 40-bit keys. The opt-in longer key
originally proposed here became the default instead (section 2).

Still to add to 8.2: **short links printed on physical objects are even more
immutable than the `301` cache makes them.** You can stop serving a key, but
you cannot get the sticker back.

---

## 9. Open questions

1. **Does OAC sign a bodyless `GET` acceptably without the viewer supplying
   `x-amz-content-sha256`?** Unverified. Section 6 sidesteps it.
2. ~~**Longer keys — worth it, and opt-in or default?**~~ Decided: 10 hex
   digits by default, 8-digit keys already issued left alone and still
   accepted by `KEY_PATTERN`. See section 2 and design.md 3.4.
3. **`EC=L` as the default?** Correct for printed stickers, mildly
   unconventional as a general default. The modal exposes the choice either
   way.
4. **Does Phase 2 justify itself?** If the workflow is "shorten, print, forget",
   the list view is a browsing tool for a thing nobody browses. Phase 1 first,
   then see.

---

## Appendix A: the uppercase trick, and why it is parked

QR alphanumeric mode packs its 45-character set at 5.5 bits per character
instead of 8, but the set is uppercase only. URLs are case-insensitive in
scheme and host and **case-sensitive in the path**, and the path here is the S3
object key.

The measured gain is real:

| | byte, lowercase | alphanumeric, uppercase |
| --- | --- | --- |
| `…/1a2b3c4d`, EC=M | 29×29 | **25×25** |
| `…link.example.com/…`, EC=M | 29×29 | **25×25** |

A whole version, which is the difference between a comfortable 15 mm sticker
and a marginal one. Getting it would mean writing a second zero-byte alias
object under the uppercased key on every create, so that `/1A2B3C4D` resolves
too. The alias namespace is disjoint from the lowercase hex keys, so it cannot
collide.

Parked because it doubles the objects, adds a partial-write failure mode
(alias written, primary not, or vice versa), and puts a second thing in the
bucket that has to be reasoned about during collision resolution — in exchange
for a saving that **choosing a shorter domain also delivers**, without any of
that. Revisit only if the domain is already short and 15 mm stickers are still
the requirement.

## Appendix B: references

- [ISO/IEC 18004 quiet zone and module size guidance — summarised by Denso Wave](https://www.qrcode.com/en/howto/code.html)
- [`qrcode-generator`](https://github.com/kazuhikoarase/qrcode-generator) (MIT)
- design.md 3.2, 4.4, 8.1, 9
