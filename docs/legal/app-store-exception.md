# Contributor policy options for App Store distribution

> **Not legal advice.** The maintainer (sole copyright holder) should decide, ideally after a
> lawyer has looked at it. TODO(user): decide, then delete the option you reject and the
> TODO markers.

## The problem

InkVault is GPL-3.0-or-later. The FSF and others hold that Apple's App Store terms (device limits,
usage rules, no way to pass on the freedoms of GPLv3 §§ 6 and 10, see "further restrictions")
are incompatible with GPLv3 for a distributor of GPL code, **unless the distributor is the
copyright holder**, who is not bound by their own licence and may license the same code to
Apple's users under Apple's terms. Today the maintainer is the sole holder, so the app can ship.
Each outside contribution adds a second copyright holder whose code the maintainer may only
distribute under the GPL, which would make an App Store release a licence violation towards
that contributor. Precedent: VLC for iOS was pulled from the App Store in January 2011 after
a contributor complained that the App Store terms violated the GPL; VLC later relicensed the
affected libraries (to LGPL-2.1-or-later) with contributor consent to return. A policy is
needed before accepting contributions.

## Option A (recommended): contributor licence agreement

`CLA.md`: contributors keep their copyright and grant the maintainer a broad licence
(including the right to distribute under app-store terms and to relicense). It is already
drafted and wired into `CONTRIBUTING.md` and the PR template.

For: gives the maintainer full flexibility (App Store, TestFlight, a future dual licence, a
future licence change), is well understood (Apache ICLA, Harmony, many foundations), and
needs no change to `LICENSE`. Against: friction and some contributors dislike CLAs;
evidence is only as good as the agreement mechanism (a PR checkbox is weaker than a signed
record); the maintainer carries the burden of the broad grant.

## Option B: a GPLv3 §7 "App Store exception" (additional permission)

GPLv3 §7 lets the copyright holder add *additional permissions* that loosen the licence, and
the pattern is established (GCC Runtime Library Exception, the GNU Classpath exception, the
OpenSSL linking exception used by many GPL projects). The exception would be stated in each
source header or in a `COPYING.exception` file, and contributors would contribute under
"GPL-3.0-or-later with the App Store exception" (inbound = outbound, which a DCO sign-off
could document).

Draft text (to be placed after the GPL notice in `README.md`/`LICENSE-EXCEPTION`):

```
Additional permission under GNU GPL version 3 section 7

If you modify this Program, or any covered work, by linking or combining it
with Apple's platform frameworks, or if you distribute the covered work
through Apple's App Store, TestFlight or another application distribution
service operated by the platform vendor ("Distribution Service"), the
licensors of this Program grant you additional permission to convey the
resulting work, in object code form only, under the terms and usage rules
that the Distribution Service applies to applications, to the extent that
those terms would otherwise conflict with the conditions of the GNU GPL,
provided that:

  1. the Corresponding Source of the work remains available under the GNU
     GPL version 3 (with this additional permission) from a public location
     you identify in the work's listing or description; and
  2. you do not use this permission to restrict anyone's rights under the GNU
     GPL in respect of the Corresponding Source.

This additional permission applies only to conveying under Distribution
Service terms; it does not relicense the source code. You may remove this
additional permission from your copy of a covered work, or from any part of
it, as GPLv3 section 7 allows.
```

For: contributors keep the full GPL and it is visibly "free software friendly", no
paperwork beyond a sign-off, and any third party may ship a fork on the App Store.
Against: the text is novel (little case law, the FSF has not blessed an "App Store
exception"; some distributors will not treat it as GPL-compatible), it only grants what it
says (no relicensing, no later move to a different licence, no proprietary builds), it must
also be applied to every file and to third-party dependencies, and the wording needs a
lawyer. It does not by itself resolve whether Apple's terms satisfy the conditions it
names. Its permission "to the extent terms would conflict" is deliberately broad; a lawyer
may narrow it.

## Recommendation

Option A. As sole copyright holder the maintainer can ship the app today; the CLA keeps that
true as contributions arrive and keeps relicensing possible, and it is the simpler, better
understood instrument. Option B suits a project that wants outside forks on the App Store and
accepts the legal novelty; the two can be combined (CLA plus exception) if wanted.

Either way: do not merge outside code before the policy is decided, and keep third-party
dependencies App-Store-compatible (swift-crypto is Apache-2.0, swift-argument-parser is
Apache-2.0; both are permissive).
