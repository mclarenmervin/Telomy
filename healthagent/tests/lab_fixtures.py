"""Synthetic lab reports that look like real ones.

Two fixtures earlier in this programme passed while testing nothing: one had
zero variance, so a z-score correctly refused to compute and the test asserted
the refusal; another omitted `user_id`, so every query returned empty and every
assertion about filtering held vacuously. Both were too clean to fail.

So these reports carry the things that actually break an extractor, laid out the
way an Indian pathology lab lays them out:

  * a **reference-range column** beside every result, which is the single most
    dangerous misread available — `Glucose 142 mg/dL 70 - 100` must yield 142,
    never 70
  * **three different dates**, none labelled "collection date" in those words
  * a **censored** result (`<3.0`) and a **qualitative** one (`Negative`)
  * the **same marker twice**, fasting and post-prandial, from one draw
  * **mixed units** across markers
  * a **footer with a phone number** and a page number, both of which are
    numbers on the page that are not results
  * a **patient name**, because the report may not be the uploader's

Positions are explicit rather than flowed, because the scanner reads column
geometry and a fixture whose columns drift would test something else.
"""

import io

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

PAGE_WIDTH, PAGE_HEIGHT = A4

# Column origins, in points from the left edge. Chosen to be unambiguously
# separated, as a real report's are.
COL_TEST = 50
COL_RESULT = 250
COL_UNIT = 330
COL_REFERENCE = 410

DEFAULT_PATIENT = "MRS SUNITA R PATNAIK"
DEFAULT_LAB = "Dr Lal PathLabs"

# (test name, result, unit, reference interval as printed)
DEFAULT_ROWS = [
    ("Glucose, Fasting", "142", "mg/dL", "70 - 100"),
    ("Glucose, Post Prandial", "198", "mg/dL", "70 - 140"),
    ("HbA1c", "7.8", "%", "4.0 - 5.6"),
    ("Haemoglobin", "13.2", "g/dL", "13.0 - 17.0"),
    ("Vitamin D, 25 - Hydroxy", "<3.0", "ng/mL", "30 - 100"),
    ("Ferritin", "60", "ng/mL", "22 - 322"),
    ("Dengue NS1 Antigen", "Negative", "", "Negative"),
]


# A report that carries all nine PhenoAge markers, plus the noise a real one
# comes with. The noise is the point: a fixture with nine clean mid-range rows
# and a single collection date would exercise almost none of the selection
# logic, which is where the mistakes live.
#
#   * a post-prandial glucose beside the fasting one -- the catalog maps both
#     labels onto `glucose_fasting`, so only the context keeps a 198 out of a
#     model fitted on fasting glucose
#   * a censored vitamin D, which must be displayable and uncomputable
#   * a qualitative result, which must never be coerced to a number
#   * markers PhenoAge does not use, which must be ignored rather than confused
#   * values spread across their ranges rather than all sitting mid-interval
PHENOAGE_ROWS = [
    ("Glucose, Fasting", "97", "mg/dL", "70 - 100"),
    ("Glucose, Post Prandial", "198", "mg/dL", "70 - 140"),
    ("Albumin", "4.2", "g/dL", "3.5 - 5.0"),
    ("Creatinine", "0.96", "mg/dL", "0.70 - 1.30"),
    ("CRP, High Sensitivity", "1.5", "mg/L", "0 - 3.0"),
    ("Lymphocytes", "28", "%", "20 - 45"),
    ("MCV", "90", "fL", "80 - 100"),
    ("RDW-CV", "13.5", "%", "11.5 - 15.0"),
    ("Alkaline Phosphatase", "75", "U/L", "35 - 120"),
    ("Total Leucocyte Count", "6.8", "10^3/uL", "4.0 - 11.0"),
    ("HbA1c", "5.4", "%", "4.0 - 5.6"),
    ("Vitamin D, 25 - Hydroxy", "<3.0", "ng/mL", "30 - 100"),
    ("Dengue NS1 Antigen", "Negative", "", "Negative"),
]


def lab_report_pdf(
    rows=None,
    patient_name: str = DEFAULT_PATIENT,
    lab_name: str = DEFAULT_LAB,
    collected_on: str = "28/09/2026 07:30",
    reported_on: str = "29/09/2026 11:04",
    registered_on: str = "28/09/2026 09:15",
    password: str | None = None,
    pages: int = 1,
) -> bytes:
    """A report as bytes. `password` encrypts it, as Indian labs routinely do."""
    rows = DEFAULT_ROWS if rows is None else rows
    buffer = io.BytesIO()

    encrypt = None
    if password is not None:
        from reportlab.lib import pdfencrypt

        encrypt = pdfencrypt.StandardEncryption(password, canPrint=1)

    pdf = canvas.Canvas(buffer, pagesize=A4, encrypt=encrypt)
    per_page = max(1, -(-len(rows) // pages))

    for page_index in range(pages):
        _header(pdf, lab_name, patient_name, collected_on, reported_on, registered_on)
        _table(pdf, rows[page_index * per_page : (page_index + 1) * per_page])
        _footer(pdf, page_index + 1, pages)
        pdf.showPage()

    pdf.save()
    return buffer.getvalue()


def _header(pdf, lab_name, patient_name, collected_on, reported_on, registered_on):
    y = PAGE_HEIGHT - 50
    pdf.setFont("Helvetica-Bold", 14)
    pdf.drawString(COL_TEST, y, lab_name)

    pdf.setFont("Helvetica", 8)
    pdf.drawString(COL_TEST, y - 14, "Plot 14, Chandrasekharpur, Bhubaneswar 751016")

    pdf.setFont("Helvetica", 9)
    y -= 40
    pdf.drawString(COL_TEST, y, f"Patient Name : {patient_name}")
    pdf.drawString(COL_REFERENCE - 50, y, "Age / Sex : 54 Y / F")
    y -= 13
    pdf.drawString(COL_TEST, y, "Ref. Doctor : DR A K MOHANTY")
    pdf.drawString(COL_REFERENCE - 50, y, "Lab No. : 0458871923")

    # Three dates, none of them saying "collection date" in those words, which
    # is exactly how real reports present them.
    y -= 13
    pdf.drawString(COL_TEST, y, f"Registered On : {registered_on}")
    y -= 13
    pdf.drawString(COL_TEST, y, f"Collected On : {collected_on}")
    y -= 13
    pdf.drawString(COL_TEST, y, f"Reported On : {reported_on}")


def _table(pdf, rows):
    y = PAGE_HEIGHT - 170

    pdf.setFont("Helvetica-Bold", 9)
    pdf.drawString(COL_TEST, y, "TEST")
    pdf.drawString(COL_RESULT, y, "RESULT")
    pdf.drawString(COL_UNIT, y, "UNIT")
    pdf.drawString(COL_REFERENCE, y, "BIOLOGICAL REF. INTERVAL")
    y -= 6
    pdf.line(COL_TEST, y, PAGE_WIDTH - 50, y)

    pdf.setFont("Helvetica", 9)
    for name, result, unit, reference in rows:
        y -= 18
        pdf.drawString(COL_TEST, y, name)
        pdf.drawString(COL_RESULT, y, result)
        pdf.drawString(COL_UNIT, y, unit)
        pdf.drawString(COL_REFERENCE, y, reference)


def _footer(pdf, page_number, page_count):
    pdf.setFont("Helvetica", 7)
    # Numbers on the page that are not results. An extractor that scans for
    # "a number near a label" finds plenty to be wrong about down here.
    pdf.drawString(COL_TEST, 50, "Customer Care : 011 - 4988 5050  |  www.example-labs.in")
    pdf.drawString(COL_TEST, 40, "Sample drawn at : Bhubaneswar Collection Centre, Code 25531")
    pdf.drawString(PAGE_WIDTH - 120, 40, f"Page {page_number} of {page_count}")


def reference_first_pdf(rows=None) -> bytes:
    """The same panel, with the reference interval printed *before* the result.

    Both orders ship. This layout is what makes the column detection load
    bearing rather than decorative: under "the first number after the label",
    every fixture that prints the result first passes while the scanner is
    quietly wrong, and this one returns 70 for a fasting glucose of 142 — a
    plausible number that nothing downstream could ever flag.
    """
    rows = DEFAULT_ROWS if rows is None else rows
    buffer = io.BytesIO()
    pdf = canvas.Canvas(buffer, pagesize=A4)

    ref_x, result_x, unit_x = 250, 410, 470
    y = PAGE_HEIGHT - 170

    pdf.setFont("Helvetica-Bold", 9)
    pdf.drawString(COL_TEST, y, "TEST")
    pdf.drawString(ref_x, y, "BIOLOGICAL REF. INTERVAL")
    pdf.drawString(result_x, y, "RESULT")
    pdf.drawString(unit_x, y, "UNIT")

    pdf.setFont("Helvetica", 9)
    for name, result, unit, reference in rows:
        y -= 18
        pdf.drawString(COL_TEST, y, name)
        pdf.drawString(ref_x, y, reference)
        pdf.drawString(result_x, y, result)
        pdf.drawString(unit_x, y, unit)

    pdf.showPage()
    pdf.save()
    return buffer.getvalue()


def flagged_rows():
    """Results carrying the lab's own out-of-range flag, as most reports print.

    The flag belongs to the cell, not to the value, and we do not re-derive it —
    we have our own ranges and the lab's view of "high" is not ours.
    """
    return [
        ("Glucose, Fasting", "142 H", "mg/dL", "70 - 100"),
        ("Haemoglobin", "10.1 L", "g/dL", "13.0 - 17.0"),
        ("Ferritin", "60", "ng/mL", "22 - 322"),
    ]


def image_only_pdf() -> bytes:
    """A page with no text layer at all — a photograph wrapped in a PDF.

    `pdfplumber` returns zero words for this, which is the signal that the OCR
    adapter is needed and that extraction cannot proceed on the text layer.
    """
    buffer = io.BytesIO()
    pdf = canvas.Canvas(buffer, pagesize=A4)
    pdf.setFillColorRGB(0.85, 0.85, 0.85)
    pdf.rect(50, 400, 400, 300, fill=1, stroke=0)
    pdf.showPage()
    pdf.save()
    return buffer.getvalue()
