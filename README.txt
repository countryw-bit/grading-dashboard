EAGLEAPPS GRADING DASHBOARD UPDATE - VERSION 10

These are complete replacement files. Copy them over the matching paths in
the EagleApps grading dashboard project:

  app/main.py
  app/static/css/dashboard.css
  app/static/js/dashboard.js
  app/static/js/roster_population.js
  app/templates/dashboard.html
  sql/activity_offering_summary.sql
  sql/grade_posting_check.sql
  sql/roster_students.sql
  sql/roster_population_summary.sql
  sql/roster_population_students.sql
  sql/roster_population_student_export.sql
  sql/roster_replacement_audit.sql

Version 10 student-export performance update
--------------------------------------------
The Student discrepancy CSV now uses one term-scoped Oracle/API request. The
version 9 implementation opened every visible section sequentially, which
could create thousands of requests and browser table renders for Fall 2026.
Version 10 loads the term's discrepancy students once, applies the currently
visible activity-offering and roster-type filters in the browser, and creates
the CSV without expanding or re-rendering each section.

Registration vs. grading-roster checker
---------------------------------------
Version 9 adds an on-demand Registration vs. grading tab. It compares distinct
active registrations with distinct students on each current grading workflow
for an exact activity offering. It identifies:

  - registration students missing from grading
  - grading students without an active registration
  - equal counts with different student populations
  - no current grading roster
  - multiple current rosters for one activity offering and roster type
  - active students stranded on abandoned/historical or removed roster rows
  - mixed discrepancies

Law and other multi-workflow courses are compared separately by ROSTER_TYPE;
blind, participation, and final-grade populations are not combined into one
inflated count. Existing duplicate-roster and duplicate-row checks remain the
authoritative duplicate reports and are not recreated by this feature.

The checker is separate from the normal dashboard load. Section summaries are
loaded only when Run roster population checker is selected. Student-level
records load only when a comparison is opened or the student discrepancy CSV
is requested.

The tab provides three exports that respect the visible section filters:

  1. section/workflow comparison CSV
  2. student-level discrepancy CSV
  3. abandoned/replacement-roster audit CSV

Verified registration mapping and current limitation
----------------------------------------------------
The checker uses only relationships verified in this environment:

  KSEN_ROSTER.REF_ID -> exact activity offering
  KSEN_ROSTER_ROW.REF_ID -> KSEN_COURSE_REG_REG.ID

To build the registration population, it examines current and historical term
roster rows, including removed and abandoned rows, and then retains current
active course registrations. It never assigns a student to a section using
COURSE_CODE alone.

This catches the known replacement-roster/HIST1801 pattern, including active
students stranded on an abandoned or removed row. However, an active
registration that has never appeared on any roster row cannot yet be assigned
to an exact activity offering by this verified path. Complete parity with the
Course Roster application requires confirming how
KSEN_COURSE_REG_REG.REG_GRP_ID resolves to the activity offering. The UI and
CSV therefore label the source ROSTER_ROW_REGISTRATION_CROSSWALK and display a
coverage note instead of overstating completeness.

Grade posting checker
---------------------
The Rosters tab includes an on-demand Run grade posting checker button. The
normal term load is unchanged. The checker compares current submitted roster
results with KSCR_AR_STU_COURSE and classifies exact matches, grades posted
through an alternate registration, missing grades, mismatches, missing
academic records, and dropped-only registrations.

The comparison is duplicate-aware without replacing the existing duplicate
roster and duplicate student checks. An alternate active registration with
the same grade is informational. An active academic record with a blank or
different grade is an exception. Results are cached in the browser until the
page is refreshed or the checker is run again.

After the checker runs, course-level exception counts are available in the
record filter, Data integrity tab, details panel, and CSV export. The Full
roster table also displays the academic grade and posting status beside the
roster grade.

Full roster details
-------------------
The existing Open details remain in place. A Full roster section is added
below them and is loaded only when a roster is opened. The term-wide summary
query is not rerun. Each roster is queried once per browser page load and the
result is cached in the browser, so closing and reopening it does not create
another database request.

The roster table shows student name, Eagle ID, actual current grade, expected-
graduate status, and duplicate-row warnings. For Law rosters with more than
one grading phase, the query prefers Final Grade, then a standard grade, then
participation or blind grade as fallbacks. A blank grade displays as a dash.
The endpoint confirms that the requested roster belongs to the term currently
selected in the dashboard.

Expected graduates ungraded filter
-----------------------------------
The record filter includes Expected graduates ungraded. It uses the summary
numbers already loaded into the page and returns rosters where expected
graduates graded is less than total expected graduates. It does not run an
additional Oracle query or add time to the term-wide data pull.

The stylesheet and JavaScript URLs include a version parameter so browsers do
not continue using an older cached dashboard after this update.

Definition
----------
Expected Graduates is the count of active roster students who have at least
one current KSEN_PROG_STATUS record whose state is active, or whose state is
eligible and type is graduate discipline. EXPED_COMPLTN_TERM_ID must match the
parent ATP ID for the term selected in the dashboard.

The displayed value is:

  current grade value present / expected graduates

Graded counts are roster-state aware. Submitted rosters count all active roster
students, not-started rosters count zero, and partially submitted rosters count
current, non-superseded KSEN_ROSTER_R records with R_VALUE_ID populated.

Diagnostics
-----------
The SQL also returns the roster's HAS_GRAD_SENIORS_IND, a source identifier,
and a discrepancy flag. The dashboard flags a discrepancy when
HAS_GRAD_SENIORS_IND = 1 but the calculated Expected Graduates count is zero.

Validation
----------
JavaScript syntax and Python application compilation were checked locally.
The Oracle queries must still be run against the target KSTRUNK environment,
because that database is not available from this workspace. Confirm student
names and roster totals on at least one small and one large roster after
installation.
