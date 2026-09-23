/* Historical/abandoned roster rows for active registrations not on a current roster. */
WITH term_parameters AS (
    SELECT UPPER(:term_code) AS selected_term,
           CASE WHEN UPPER(:term_code) LIKE '%SUMM'
                THEN SUBSTR(UPPER(:term_code), 1, LENGTH(UPPER(:term_code)) - 1)
                ELSE UPPER(:term_code) END AS term_prefix
    FROM dual
),
selected_atps AS (
    SELECT a.id, a.cd, a.name
    FROM {{SCHEMA}}.ksen_atp a
    CROSS JOIN term_parameters p
    WHERE UPPER(a.cd) = p.selected_term
       OR UPPER(a.cd) LIKE p.term_prefix || '%'
),
term_rosters AS (
    SELECT
        r.id AS roster_id,
        r.ref_id AS activity_offering_id,
        r.name AS roster_name,
        r.roster_type,
        r.roster_state,
        r.atp_id,
        a.cd AS subterm_code,
        a.name AS subterm_name,
        CASE
            WHEN (r.eff_dt IS NULL OR r.eff_dt <= SYSTIMESTAMP)
             AND (r.exp_dt IS NULL OR r.exp_dt > SYSTIMESTAMP)
             AND r.roster_state IN (
                 'kuali.grading.roster.state.submitted',
                 'kuali.grading.roster.state.partial.submitted',
                 'kuali.grading.roster.state.notstarted'
             ) THEN 'Y' ELSE 'N'
        END AS current_roster_ind
    FROM {{SCHEMA}}.ksen_roster r
    JOIN selected_atps a ON a.id = r.atp_id
),
current_people AS (
    SELECT DISTINCT tr.activity_offering_id, reg.pers_id
    FROM term_rosters tr
    JOIN {{SCHEMA}}.ksen_roster_row rr ON rr.roster_id = tr.roster_id
    JOIN {{SCHEMA}}.ksen_course_reg_reg reg ON reg.id = rr.ref_id
    WHERE tr.current_roster_ind = 'Y'
      AND rr.roster_row_state <>
          'kuali.grading.roster.row.state.removed'
      AND (rr.eff_dt IS NULL OR rr.eff_dt <= SYSTIMESTAMP)
      AND (rr.exp_dt IS NULL OR rr.exp_dt > SYSTIMESTAMP)
),
preferred_person_name AS (
    SELECT pers_id, composite_name
    FROM (
        SELECT pn.pers_id, pn.composite_name,
               ROW_NUMBER() OVER (
                   PARTITION BY pn.pers_id
                   ORDER BY CASE WHEN pn.pers_name_state =
                       'kuali.person.person.name.state.active'
                       THEN 0 ELSE 1 END,
                       pn.eff_dt DESC NULLS LAST,
                       pn.updatetime DESC NULLS LAST,
                       pn.id
               ) AS rn
        FROM {{SCHEMA}}.ksen_pers_name pn
        WHERE (pn.eff_dt IS NULL OR pn.eff_dt <= SYSTIMESTAMP)
          AND (pn.exp_dt IS NULL OR pn.exp_dt > SYSTIMESTAMP)
    ) WHERE rn = 1
)
SELECT DISTINCT
    tr.subterm_code,
    tr.subterm_name,
    tr.activity_offering_id,
    tr.roster_name,
    tr.roster_type,
    tr.roster_id AS historical_roster_id,
    tr.roster_state AS historical_roster_state,
    rr.id AS historical_roster_row_id,
    rr.roster_row_state AS historical_roster_row_state,
    reg.id AS registration_id,
    reg.pers_id AS student_id,
    NVL(pn.composite_name, reg.pers_id) AS student_name,
    reg.course_code,
    reg.reg_state AS registration_state,
    CASE
        WHEN tr.roster_state = 'kuali.grading.roster.state.abandoned'
        THEN 'ABANDONED_ROSTER'
        WHEN rr.roster_row_state =
             'kuali.grading.roster.row.state.removed'
        THEN 'REMOVED_ROW'
        ELSE 'HISTORICAL_ROSTER'
    END AS audit_reason
FROM term_rosters tr
JOIN {{SCHEMA}}.ksen_roster_row rr ON rr.roster_id = tr.roster_id
JOIN {{SCHEMA}}.ksen_course_reg_reg reg ON reg.id = rr.ref_id
LEFT JOIN preferred_person_name pn ON pn.pers_id = reg.pers_id
WHERE reg.reg_state =
      'kuali.courseregistration.registration.state.active'
  AND (reg.eff_dt IS NULL OR reg.eff_dt <= SYSTIMESTAMP)
  AND (reg.exp_dt IS NULL OR reg.exp_dt > SYSTIMESTAMP)
  AND (tr.current_roster_ind = 'N'
       OR rr.roster_row_state =
          'kuali.grading.roster.row.state.removed')
  AND NOT EXISTS (
      SELECT 1 FROM current_people cp
      WHERE cp.activity_offering_id = tr.activity_offering_id
        AND cp.pers_id = reg.pers_id
  )
ORDER BY tr.subterm_code, tr.roster_name, student_name
FETCH FIRST 20000 ROWS ONLY
