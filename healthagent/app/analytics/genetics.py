"""Reading a genetics export, and refusing almost all of it.

Three separate jobs, and the first one is the reason the other two are safe.

**The import keeps only what the allowlist names.** Everything else is
discarded at parse time -- not flagged, not stored behind a setting, not
written to a column somebody could query later. There is no table it could be
recovered from because it never reaches one. `variant_catalog.py` says why
that is an allowlist rather than a blocklist.

**A variant is only ever context beside a measured marker.** `context_for`
attaches a stored genotype to a lab result the user actually has, and a
variant with no matching result is not returned at all. There is deliberately
no function here that answers "what variants does this person have", and
deliberately no tool and no loader method either: the plan's rule is that a
variant may never ORIGINATE an insight, and the way to guarantee that is to
make the standalone question unaskable rather than to ask a model nicely.

**And the question people will actually ask is answered before the model
runs.** "Do I have the Alzheimer's gene" is the single highest-stakes
sentence a user can type into this product, and a model's behaviour varies
between two identical runs -- F7 asked the same question twice and got a
misattributed signature once. So it is a deterministic screen, in the shape
`screen_for_emergency` already established, and the answer is true: we never
read it.
"""

import re
from dataclasses import dataclass

from app.analytics import variant_catalog

#: What `import_raw` recognised.
TWENTY_THREE_AND_ME = "23andme"
VCF = "vcf"

#: 23andMe writes this where the chip could not read the locus. Storing it as
#: a genotype would be inventing one.
NO_CALL = {"--", "__", ""}


class UnreadableGeneticFile(Exception):
    """Not a format we recognise. Refused rather than guessed at — a
    mis-parsed genotype is worse than no genotype."""


@dataclass(frozen=True)
class Call:
    rsid: str
    genotype: str


@dataclass(frozen=True)
class Import:
    """What came out of a file.

    `discarded` is a count and nothing else. "We read 600,000 rows and kept
    three" is useful to a person; which of the other 599,997 were interesting
    is precisely the thing being refused, so no identity of a discarded row
    appears in this object, in a log line, or in its repr.
    """

    format: str
    calls: tuple[Call, ...]
    read: int
    discarded: int
    conflicts: int


# ── Parsing ──────────────────────────────────────────────────────────────────

_23ANDME_ROW = re.compile(r"^(rs\d+)\t\S+\t\S+\t([ACGTDI\-_]{1,2})\s*$", re.I)


def _parse_23andme(lines) -> list[Call]:
    out = []
    for line in lines:
        match = _23ANDME_ROW.match(line)
        if not match:
            continue
        genotype = match.group(2).upper()
        if genotype in NO_CALL:
            continue
        out.append(Call(match.group(1).lower(), genotype))
    return out


def _vcf_genotype(ref: str, alt: str, sample: str, fmt: str) -> str | None:
    """A GT field turned into the two-letter call the rest of this uses.

    Multi-allelic ALT fields are skipped rather than guessed at: picking the
    first alternate would silently report a genotype the file did not state.
    """
    keys = fmt.split(":")
    if "GT" not in keys:
        return None
    value = sample.split(":")[keys.index("GT")]
    alleles = re.split(r"[/|]", value)
    if any(a in (".", "") for a in alleles) or len(alleles) != 2:
        return None
    if "," in alt:
        return None

    lookup = {"0": ref.upper(), "1": alt.upper()}
    try:
        return "".join(sorted(lookup[a] for a in alleles))
    except KeyError:
        return None


def _parse_vcf(lines) -> list[Call]:
    out = []
    for line in lines:
        if line.startswith("#"):
            continue
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 10:
            continue
        rsid = fields[2].strip().lower()
        if not rsid.startswith("rs"):
            continue
        genotype = _vcf_genotype(fields[3], fields[4], fields[9], fields[8])
        if genotype:
            out.append(Call(rsid, genotype))
    return out


def import_raw(text: str, path=None) -> Import:
    """Read a genetics export and keep only the allowlisted wellness variants.

    The filter is applied here, between parsing and returning, so it cannot
    be bypassed by arriving in a different file format or by a caller that
    forgot to apply it.
    """
    lines = (text or "").splitlines()
    if not lines:
        raise UnreadableGeneticFile("the file is empty")

    if any(line.startswith("##fileformat=VCF") for line in lines[:20]):
        fmt, parsed = VCF, _parse_vcf(lines)
    else:
        parsed = _parse_23andme(lines)
        fmt = TWENTY_THREE_AND_ME
        if not parsed:
            raise UnreadableGeneticFile(
                "this is not a 23andMe raw export or a VCF, and a genotype "
                "guessed out of an unknown format is worse than none"
            )

    allowed = variant_catalog.allowed_rsids(path)
    kept: dict[str, Call] = {}
    conflicts = 0
    for call in parsed:
        if call.rsid not in allowed:
            continue
        if call.rsid in kept:
            # A merged export can repeat a locus. Two genotypes for one
            # position is a contradiction, and taking the later one silently
            # would make the stored value depend on file order.
            conflicts += 1
            continue
        kept[call.rsid] = call

    return Import(
        format=fmt,
        calls=tuple(kept.values()),
        read=len(parsed),
        discarded=len(parsed) - len(kept) - conflicts,
        conflicts=conflicts,
    )


# ── Context, and only context ────────────────────────────────────────────────

def context_for_results(stored_variants, biomarker_results, path=None) -> dict:
    """{biomarker_id: [variant context]} for markers this user has results for.

    A variant with no matching result is absent, not empty. That is the whole
    rule: there is no marker for it to be context for, so there is nothing to
    say, and the function cannot be used to answer "what variants do I have".

    A stored variant that is no longer on the allowlist is also dropped —
    defence in depth, so that removing an entry from the catalog stops it
    being shown without waiting for a migration to delete the rows.
    """
    measured = {
        row.get("biomarker_id")
        for row in biomarker_results
        if row.get("biomarker_id")
    }
    if not measured:
        return {}

    out: dict[str, list[dict]] = {}
    for row in stored_variants:
        rsid = str(row.get("rsid") or "").strip().lower()
        variant = variant_catalog.get(rsid, path)
        if variant is None:
            continue
        genotype = str(row.get("genotype") or "").strip().upper()
        if not genotype:
            continue
        review = variant_catalog.review_status(rsid, path)
        for biomarker_id in variant.context_for:
            if biomarker_id not in measured:
                continue
            out.setdefault(biomarker_id, []).append({
                "rsid": variant.rsid,
                "gene": variant.gene,
                "trait": variant.trait,
                "genotype": genotype,
                # Withheld until signed, exactly as a lab value's verdict is.
                # The genotype is a fact about this person; what it means
                # about them is the clinical claim.
                "note": variant.note if review.reviewed else None,
                "citation": variant.citation if review.reviewed else None,
                "note_reviewed": review.reviewed,
            })
    return out


# ── The question, answered before the model ──────────────────────────────────

#: Written out rather than left to the model, because this is the one place
#: where "the model usually gets it right" is not good enough. It is also the
#: one answer in the product that is unambiguously TRUE regardless of what
#: the user uploaded: we never read those loci.
GENETIC_RISK_RESPONSE = (
    "I have no way to answer that, and that is deliberate rather than a gap. "
    "When a genetics file is imported we read only a short list of "
    "wellness-related variants — things that sit alongside a blood result you "
    "have already had, like folate or vitamin D. Everything else in the file, "
    "including the variants that carry disease risk, is discarded as it is "
    "read and is never stored. A question about inherited risk is worth "
    "asking, and it belongs with a doctor or a genetic counsellor who can "
    "arrange the right test and talk you through what an answer would mean "
    "before you get it."
)

# (rule name, pattern). The name is logged; the message text never is.
#
# Each pattern requires a genetic framing AND a condition, or an explicitly
# genetic term. "My grandmother had dementia, is my sleep okay" must get an
# answer about sleep: a screen that fires on any disease word would make the
# concierge useless and train people to ignore it.
_GENE_WORDS = r"gene|genes|genetic\w*|dna|variant|allele|snp|carrier|inherit\w*|hereditary|genome|23andme"
_CONDITIONS = (
    r"alzheimer\w*|dementia|parkinson\w*|huntington\w*|cancer|tumou?r|"
    r"brca|breast cancer|ovarian cancer|bowel cancer|colon cancer|"
    r"haemochromatosis|hemochromatosis|cystic fibrosis|sickle cell|"
    r"thalassaem\w*|thalassem\w*|celiac|coeliac|diabetes|heart disease"
)

_RULES = [
    # The named hazard, in the words people actually use.
    ("alzheimers", re.compile(
        rf"\b(?:{_GENE_WORDS})\b[^.?]{{0,40}}\b(?:alzheimer\w*|dementia)\b"
        rf"|\b(?:alzheimer\w*|dementia)\b[^.?]{{0,40}}\b(?:{_GENE_WORDS})\b",
        re.I)),
    # APOE by name, with or without a disease attached. Nobody types "apoe4"
    # without knowing what they are asking.
    ("apoe", re.compile(r"\bapo\s?-?e\s?-?[234]?\b|\bapoe\d?\b", re.I)),
    ("brca", re.compile(r"\bbrca\s?-?[12]?\b", re.I)),
    # Any other genetic framing beside a condition.
    ("risk_genotype", re.compile(
        rf"\b(?:{_GENE_WORDS})\b[^.?]{{0,60}}\b(?:{_CONDITIONS})\b"
        rf"|\b(?:{_CONDITIONS})\b[^.?]{{0,60}}\b(?:{_GENE_WORDS})\b",
        re.I)),
    # "Am I a carrier for X" and "do I have the X gene" without the word gene.
    ("carrier_status", re.compile(
        rf"\b(?:carrier|predispos\w*|susceptib\w*)\b[^.?]{{0,40}}\b(?:{_CONDITIONS})\b",
        re.I)),
]


@dataclass(frozen=True)
class GeneticRiskMatch:
    matched_rule: str  # for audit — never the text that matched
    response: str


def screen_for_genetic_risk(text: str | None) -> GeneticRiskMatch | None:
    """A question about an inherited disease risk, or None.

    Runs before the model, like the emergency screen, and for the same
    reason: the answer must not depend on which generation the provider
    happened to produce. Unlike the emergency screen this is not urgent, so
    it sits after it in the turn — somebody describing chest pain and asking
    about their genes needs the first answer.
    """
    if not text or not text.strip():
        return None
    for name, pattern in _RULES:
        if pattern.search(text):
            return GeneticRiskMatch(matched_rule=name, response=GENETIC_RISK_RESPONSE)
    return None
